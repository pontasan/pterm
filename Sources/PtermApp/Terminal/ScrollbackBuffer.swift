import Foundation
import PtermCore

/// Swift wrapper around the C ring buffer for terminal scrollback storage.
///
/// Serializes Cell arrays to a compact binary format
/// and stores them in the circular ring buffer. When the buffer is full,
/// the oldest rows are automatically evicted.
///
/// Thread safety: Callers must manage external synchronization.
/// In practice, the TerminalController lock covers all access.
final class ScrollbackBuffer {
    struct RowEncodingHint {
        enum Kind {
            case unknown
            case compactDefault(serializedCount: Int)
            case compactUniformAttributes(sharedAttributes: CellAttributes, serializedCount: Int)
            case full
        }

        let kind: Kind

        static let unknown = RowEncodingHint(kind: .unknown)
        static let full = RowEncodingHint(kind: .full)

    }

    struct BufferedRow {
        enum Storage {
            case cells([Cell])
            case encoded([UInt8])
        }

        let storage: Storage
        let cellCount: Int
        let isWrapped: Bool
        let encodingHint: RowEncodingHint

        var cells: [Cell] {
            switch storage {
            case .cells(let cells):
                return cells
            case .encoded(let bytes):
                var decoded: [Cell] = []
                _ = bytes.withUnsafeBufferPointer { encoded in
                    guard let baseAddress = encoded.baseAddress else { return false }
                    return ScrollbackBuffer.deserializeBufferedRow(
                        encodedBytes: baseAddress,
                        length: bytes.count,
                        into: &decoded
                    )
                }
                return decoded
            }
        }

        init(cells: [Cell], cellCount: Int? = nil, isWrapped: Bool, encodingHint: RowEncodingHint = .unknown) {
            self.storage = .cells(cells)
            self.cellCount = cellCount ?? cells.count
            self.isWrapped = isWrapped
            self.encodingHint = encodingHint
        }

        init(cells: ArraySlice<Cell>, cellCount: Int, isWrapped: Bool, encodingHint: RowEncodingHint = .unknown) {
            let boundedCount = min(cellCount, cells.count)
            self.cellCount = cellCount
            self.isWrapped = isWrapped
            self.encodingHint = encodingHint
            if let encodedBytes = ScrollbackBuffer.encodeBufferedRowIfPossible(
                cells: cells,
                cellCount: boundedCount,
                hint: encodingHint
            ) {
                self.storage = .encoded(encodedBytes)
            } else {
                self.storage = .cells(Array(cells.prefix(boundedCount)))
            }
        }
    }

    private enum RowEncodingPlan {
        case compactDefault(serializedCount: Int)
        case compactUniformAttributes(sharedAttributes: CellAttributes, serializedCount: Int)
        case full
    }

    private enum RowFormat {
        static let compactDefault = UInt8(0x01)
        static let compactUniformAttributes = UInt8(0x02)
        static let compactDefaultTrimmed = UInt8(0x03)
        static let compactUniformAttributesTrimmed = UInt8(0x04)
    }

    /// Underlying C ring buffer
    private var ringBuffer: UnsafeMutablePointer<RingBuffer>?
    private let persistentPath: String?
    private var unlinkOnDeinit: Bool
    private let maxCapacityBytes: Int
    private let recentRowsByteBudget: Int
    private var recentRows: [BufferedRow] = []
    private var recentSerializedBytesUsed = 0

    /// Number of rows currently stored
    var rowCount: Int {
        archivedRowCount + recentRows.count
    }

    /// Cumulative number of rows evicted since creation (monotonically increasing).
    /// Used to create stable global absolute row addresses that survive buffer eviction.
    var totalEvictedRows: Int {
        guard let rb = ringBuffer else { return 0 }
        return Int(ring_buffer_evicted_rows(rb))
    }

    /// Total allocated capacity in bytes
    var capacity: Int {
        guard let rb = ringBuffer else { return 0 }
        return ring_buffer_capacity(rb)
    }

    var rowIndexCapacity: Int {
        guard let rb = ringBuffer else { return 0 }
        return Int(ring_buffer_row_index_capacity(rb))
    }

    var bytesUsed: Int {
        archivedBytesUsed + recentSerializedBytesUsed
    }

    var serializationBufferCapacity: Int {
        serializeBufCapacity
    }

    private struct SerializedRowScratch {
        let plan: RowEncodingPlan
        let cellCount: Int
        let byteCount: Int
        let isWrapped: Bool
    }

    /// Reusable serialization buffer (avoids per-call allocation)
    private var serializeBuf: UnsafeMutablePointer<UInt8>?
    private var serializeBufCapacity: Int = 0
    private var serializedRowsScratch: [SerializedRowScratch] = []
    private var rowOffsetsScratch: [UInt32] = []
    private var rowLengthsScratch: [UInt32] = []
    private var rowContinuationsScratch: [Bool] = []
    private static let serializationBufferPageSize = 4096

    /// Bytes per cell in binary format
    static let bytesPerCell = fullCellBytes
    private static let compactRowHeaderBytes = 1
    private static let compactTrimmedRowHeaderBytes = 3
    private static let uniformAttributesHeaderBytes = 15
    private static let uniformAttributesTrimmedHeaderBytes = 17
    private static let uniformAttributesBytesPerCell = 5
    private static let fullCellBytes = 60
    // Treat large heap-backed startup budgets as permission to pre-size row metadata so
    // short-row workloads (like line-oriented logs or `seq`) do not immediately grow the
    // row index. Small budgets keep the ring buffer's default row floor so metadata cannot
    // starve data capacity, and mmap-backed buffers keep their persisted layout stable.
    private static let eagerRowIndexReserveMinimumInitialCapacity = 1 * 1024 * 1024
    private static let targetInitialBytesPerStoredRow = 64
    private static let rowIndexReserveSoftLimit = 131_072
    init(initialCapacity: Int,
         maxCapacity: Int,
         persistentPath: String? = nil) {
        self.maxCapacityBytes = maxCapacity
        self.recentRowsByteBudget = max(32 * 1024, min(maxCapacity / 8, 512 * 1024))
        self.persistentPath = persistentPath
        self.unlinkOnDeinit = false

        if let persistentPath {
            guard let ringBuffer = ring_buffer_create_mmap_sized(
                persistentPath,
                initialCapacity,
                maxCapacity
            ) else {
                fatalError("Failed to create mmap-backed scrollback buffer at \(persistentPath)")
            }
            self.ringBuffer = ringBuffer
        } else {
            guard let ringBuffer = ring_buffer_create_sized(initialCapacity, maxCapacity) else {
                fatalError("Failed to create scrollback buffer with initial capacity \(initialCapacity) and max capacity \(maxCapacity)")
            }
            self.ringBuffer = ringBuffer
        }

        if let ringBuffer,
           persistentPath == nil,
           initialCapacity >= Self.eagerRowIndexReserveMinimumInitialCapacity {
            let estimatedRows = max(
                Int(RING_BUFFER_MIN_ROWS),
                min(
                    initialCapacity / Self.targetInitialBytesPerStoredRow,
                    Self.rowIndexReserveSoftLimit
                )
            )
            precondition(
                ring_buffer_reserve_row_index_capacity(ringBuffer, UInt32(estimatedRows)),
                "Failed to reserve row index capacity \(estimatedRows)"
            )
        }
    }

    deinit {
        flushPendingRows()
        if let rb = ringBuffer {
            if unlinkOnDeinit {
                ring_buffer_destroy_and_unlink(rb)
            } else {
                ring_buffer_destroy(rb)
            }
        }
        if let buf = serializeBuf {
            buf.deallocate()
        }
    }

    // MARK: - Row Operations

    /// Append a row of cells to the scrollback buffer.
    func appendRow(_ cells: ArraySlice<Cell>, isWrapped: Bool, encodingHint: RowEncodingHint = .unknown) {
        appendRow(cells, cellCount: cells.count, isWrapped: isWrapped, encodingHint: encodingHint)
    }

    /// Append a row slice without forcing callers to materialize or trim into a new Array.
    func appendRow(_ cells: ArraySlice<Cell>,
                   cellCount: Int,
                   isWrapped: Bool,
                   encodingHint: RowEncodingHint = .unknown) {
        let boundedCount = min(cellCount, cells.count)
        let bufferedRow = BufferedRow(cells: cells,
                                      cellCount: boundedCount,
                                      isWrapped: isWrapped,
                                      encodingHint: encodingHint)
        appendBufferedRow(bufferedRow)
    }

    /// Append multiple rows while reusing the same serialization scratch buffer.
    func appendRows(_ rows: [BufferedRow]) {
        guard !rows.isEmpty else { return }
        for row in rows {
            appendBufferedRow(row)
        }
    }

    /// Append a pre-buffered row without rebuilding storage around it.
    func appendRow(_ row: BufferedRow) {
        appendBufferedRow(row)
    }

    func flushPendingRows() {
        flushRecentRowsToArchived()
    }

    private var archivedRowCount: Int {
        guard let rb = ringBuffer else { return 0 }
        return Int(ring_buffer_row_count(rb))
    }

    private var archivedBytesUsed: Int {
        guard let rb = ringBuffer else { return 0 }
        return Int(ring_buffer_bytes_used(rb))
    }

    private func appendBufferedRow(_ row: BufferedRow) {
        let byteCount = Self.serializedByteCount(forRow: row)
        if serializeBufCapacity < byteCount || shouldShrinkSerializationBuffer(requiredByteCount: byteCount) {
            resizeSerializationBuffer(requiredByteCount: byteCount)
        }
        if shouldAppendDirectlyToArchived(newRowByteCount: byteCount) {
            flushRecentRowsToArchived()
            appendRowsToArchived([row])
            return
        }
        recentRows.append(row)
        recentSerializedBytesUsed += byteCount
    }

    private func shouldAppendDirectlyToArchived(newRowByteCount: Int) -> Bool {
        if persistentPath != nil {
            return true
        }
        let projectedBytes = archivedBytesUsed + recentSerializedBytesUsed + newRowByteCount
        if projectedBytes > maxCapacityBytes {
            return true
        }
        if recentSerializedBytesUsed > recentRowsByteBudget {
            return true
        }
        return false
    }

    private func flushRecentRowsToArchived() {
        guard !recentRows.isEmpty else { return }
        let rows = recentRows
        recentRows.removeAll(keepingCapacity: true)
        recentSerializedBytesUsed = 0
        appendRowsToArchived(rows)
    }

    private func appendRowsToArchived(_ rows: [BufferedRow]) {
        guard let rb = ringBuffer, !rows.isEmpty else { return }
        ensureAppendRowsScratchCapacity(rowCount: rows.count)
        serializedRowsScratch.removeAll(keepingCapacity: true)
        var totalByteCount = 0
        for row in rows {
            let cellCount = row.cellCount
            let plan: RowEncodingPlan
            let byteCount: Int
            switch row.storage {
            case .encoded(let bytes):
                plan = .full
                byteCount = bytes.count
            case .cells(let cells):
                plan = Self.encodingPlan(for: cells, cellCount: cellCount, hint: row.encodingHint)
                byteCount = Self.serializedByteCount(for: plan, cellCount: cellCount)
            }
            serializedRowsScratch.append(
                SerializedRowScratch(
                    plan: plan,
                    cellCount: cellCount,
                    byteCount: byteCount,
                    isWrapped: row.isWrapped
                )
            )
            totalByteCount += byteCount
        }

        if serializeBufCapacity < totalByteCount || shouldShrinkSerializationBuffer(requiredByteCount: totalByteCount) {
            resizeSerializationBuffer(requiredByteCount: totalByteCount)
        }

        guard let buf = serializeBuf else { return }

        var runningOffset = 0
        for index in rows.indices {
            let row = rows[index]
            let serialized = serializedRowsScratch[index]
            rowOffsetsScratch[index] = UInt32(runningOffset)
            rowLengthsScratch[index] = UInt32(serialized.byteCount)
            rowContinuationsScratch[index] = serialized.isWrapped
            switch row.storage {
            case .encoded(let bytes):
                bytes.withUnsafeBufferPointer { encoded in
                    guard let baseAddress = encoded.baseAddress else { return }
                    (buf + runningOffset).update(from: baseAddress, count: bytes.count)
                }
            case .cells(let cells):
                Self.serializeRow(cells,
                                  cellCount: serialized.cellCount,
                                  using: serialized.plan,
                                  into: buf + runningOffset)
            }
            runningOffset += serialized.byteCount
        }
        rowOffsetsScratch.withUnsafeBufferPointer { offsets in
            rowLengthsScratch.withUnsafeBufferPointer { lengths in
                rowContinuationsScratch.withUnsafeBufferPointer { continuations in
                    _ = ring_buffer_append_rows(
                        rb,
                        buf,
                        offsets.baseAddress,
                        lengths.baseAddress,
                        continuations.baseAddress,
                        UInt32(rows.count)
                    )
                }
            }
        }
    }

    private func ensureAppendRowsScratchCapacity(rowCount: Int) {
        guard rowCount > 0 else { return }
        if serializedRowsScratch.capacity < rowCount {
            serializedRowsScratch.reserveCapacity(rowCount)
        }
        if rowOffsetsScratch.count < rowCount {
            rowOffsetsScratch = Array(repeating: 0, count: rowCount)
        }
        if rowLengthsScratch.count < rowCount {
            rowLengthsScratch = Array(repeating: 0, count: rowCount)
        }
        if rowContinuationsScratch.count < rowCount {
            rowContinuationsScratch = Array(repeating: false, count: rowCount)
        }
    }

    /// Get a row of cells from the scrollback buffer.
    /// rowIndex 0 = oldest row.
    /// Returns nil if the row doesn't exist.
    func getRow(at rowIndex: Int) -> [Cell]? {
        var cells: [Cell] = []
        guard getRow(at: rowIndex, into: &cells) else { return nil }
        return cells
    }

    @discardableResult
    func getRow(at rowIndex: Int, into destination: inout [Cell]) -> Bool {
        let archivedCount = archivedRowCount
        if rowIndex >= archivedCount {
            let recentIndex = rowIndex - archivedCount
            guard recentIndex >= 0, recentIndex < recentRows.count else {
                destination.removeAll(keepingCapacity: true)
                return false
            }
            destination.removeAll(keepingCapacity: true)
            destination.append(contentsOf: recentRows[recentIndex].cells)
            return true
        }

        guard let rb = ringBuffer else {
            destination.removeAll(keepingCapacity: true)
            return false
        }

        var dataPtr: UnsafePointer<UInt8>?
        var length: UInt32 = 0
        var continuation: Bool = false

        guard ring_buffer_get_row(rb, UInt32(rowIndex), &dataPtr, &length, &continuation) else {
            destination.removeAll(keepingCapacity: true)
            return false
        }

        guard let ptr = dataPtr, length > 0 else {
            destination.removeAll(keepingCapacity: true)
            return false
        }

        let cellCount: Int
        destination.removeAll(keepingCapacity: true)
        if Self.isCompactDefaultRowFormat(length: Int(length), firstByte: ptr[0]) {
            let trimmed = ptr[0] == RowFormat.compactDefaultTrimmed
            let headerBytes = trimmed ? Self.compactTrimmedRowHeaderBytes : Self.compactRowHeaderBytes
            let serializedCount = (Int(length) - headerBytes) / MemoryLayout<UInt32>.size
            cellCount = trimmed ? Int(Self.deserializeUInt16(from: ptr + 1)) : serializedCount
            destination.reserveCapacity(cellCount)
            var offset = headerBytes
            for _ in 0..<serializedCount {
                destination.append(Self.deserializeCompactDefaultCell(from: ptr + offset))
                offset += MemoryLayout<UInt32>.size
            }
            if trimmed && cellCount > serializedCount {
                destination.append(contentsOf: repeatElement(Cell.empty, count: cellCount - serializedCount))
            }
        } else if Self.isCompactUniformAttributesRowFormat(length: Int(length), firstByte: ptr[0]) {
            let trimmed = ptr[0] == RowFormat.compactUniformAttributesTrimmed
            let sharedAttributes = Self.deserializeAttributes(
                foregroundPtr: ptr + 1,
                backgroundPtr: ptr + 5,
                flags: ptr[9],
                underlineStyleRaw: ptr[10],
                underlineColorPtr: ptr + 11
            )
            let headerBytes = trimmed ? Self.uniformAttributesTrimmedHeaderBytes : Self.uniformAttributesHeaderBytes
            let serializedCount = (Int(length) - headerBytes) / Self.uniformAttributesBytesPerCell
            cellCount = trimmed ? Int(Self.deserializeUInt16(from: ptr + 15)) : serializedCount
            destination.reserveCapacity(cellCount)
            var offset = headerBytes
            for _ in 0..<serializedCount {
                destination.append(Self.deserializeCompactUniformAttributeCell(from: ptr + offset,
                                                                               sharedAttributes: sharedAttributes))
                offset += Self.uniformAttributesBytesPerCell
            }
            if trimmed && cellCount > serializedCount {
                let blank = Cell(
                    codepoint: Cell.empty.codepoint,
                    attributes: sharedAttributes,
                    width: Cell.empty.width,
                    isWideContinuation: false
                )
                destination.append(contentsOf: repeatElement(blank, count: cellCount - serializedCount))
            }
        } else {
            cellCount = Int(length) / Self.bytesPerCell
            destination.reserveCapacity(cellCount)
            for i in 0..<cellCount {
                destination.append(Self.deserializeCell(from: ptr + i * Self.bytesPerCell))
            }
        }

        return true
    }

    /// Check if a row is a soft-wrapped continuation.
    func isRowWrapped(at rowIndex: Int) -> Bool {
        let archivedCount = archivedRowCount
        if rowIndex >= archivedCount {
            let recentIndex = rowIndex - archivedCount
            guard recentIndex >= 0, recentIndex < recentRows.count else { return false }
            return recentRows[recentIndex].isWrapped
        }

        guard let rb = ringBuffer else { return false }
        var continuation: Bool = false
        guard ring_buffer_get_row(rb, UInt32(rowIndex), nil, nil, &continuation) else {
            return false
        }
        return continuation
    }

    // MARK: - Reflow

    /// Re-wrap all scrollback rows at a new column width.
    ///
    /// Reconstructs logical lines by joining soft-wrapped rows,
    /// then re-wraps them at `newCols`. The ring buffer is rebuilt in place.
    func reflow(oldCols: Int, newCols: Int) {
        guard oldCols != newCols, newCols > 0 else { return }
        let totalRows = rowCount
        guard totalRows > 0 else { return }

        // 1. Flush pending rows so everything is in the ring buffer
        flushPendingRows()

        // 2. Read all rows and their wrap flags
        var allRows: [(cells: [Cell], isWrapped: Bool)] = []
        allRows.reserveCapacity(totalRows)
        var cellBuf: [Cell] = []
        for i in 0..<totalRows {
            cellBuf.removeAll(keepingCapacity: true)
            _ = getRow(at: i, into: &cellBuf)
            allRows.append((cells: cellBuf, isWrapped: isRowWrapped(at: i)))
        }

        // 3. Reconstruct logical lines by joining soft-wrapped rows
        var logicalLines: [[Cell]] = []
        var currentLine: [Cell] = []
        for (index, row) in allRows.enumerated() {
            if index == 0 || !row.isWrapped {
                if index > 0 {
                    logicalLines.append(currentLine)
                }
                currentLine = trimTrailingEmpty(row.cells)
            } else {
                // Soft-wrapped continuation: pad previous segment to oldCols, then append
                currentLine = padToWidth(currentLine, width: oldCols) + trimTrailingEmpty(row.cells)
            }
        }
        logicalLines.append(currentLine)

        // 4. Clear the buffer
        guard let rb = ringBuffer else { return }
        ring_buffer_clear(rb)
        recentRows.removeAll(keepingCapacity: true)
        recentSerializedBytesUsed = 0

        // 5. Re-wrap each logical line at newCols and append
        var newRows: [BufferedRow] = []
        newRows.reserveCapacity(totalRows)
        for logicalLine in logicalLines {
            let wrapped = wrapLogicalLine(logicalLine, cols: newCols)
            for (rowInLine, rowCells) in wrapped.enumerated() {
                let isWrapped = rowInLine > 0
                newRows.append(BufferedRow(
                    cells: rowCells,
                    cellCount: rowCells.count,
                    isWrapped: isWrapped
                ))
            }
        }

        // 6. Append all new rows
        appendRows(newRows)
        flushPendingRows()
    }

    /// Trim trailing empty (space with default attributes) cells.
    private func trimTrailingEmpty(_ cells: [Cell]) -> [Cell] {
        var end = cells.count
        while end > 0
                && cells[end - 1].codepoint == 0x20
                && cells[end - 1].attributes == .default {
            end -= 1
        }
        return Array(cells.prefix(end))
    }

    /// Pad a cell array to a given width with empty cells.
    private func padToWidth(_ line: [Cell], width: Int) -> [Cell] {
        if line.count >= width { return line }
        return line + Array(repeating: Cell.empty, count: width - line.count)
    }

    /// Split a logical line into rows at a given column width.
    private func wrapLogicalLine(_ line: [Cell], cols: Int) -> [[Cell]] {
        if line.isEmpty {
            return [[]]
        }
        var result: [[Cell]] = []
        var idx = 0
        while idx < line.count {
            let end = min(idx + cols, line.count)
            result.append(Array(line[idx..<end]))
            idx = end
        }
        if result.isEmpty {
            result.append([])
        }
        return result
    }

    /// Clear all scrollback data.
    func clear() {
        guard let rb = ringBuffer else { return }
        ring_buffer_clear(rb)
        recentRows.removeAll(keepingCapacity: true)
        recentSerializedBytesUsed = 0
        releaseSerializationBuffer()
    }

    func liveInlineImageIDs() -> Set<Int> {
        var ids = Set<Int>()
        ids.reserveCapacity(8)
        var rowBuffer: [Cell] = []
        rowBuffer.reserveCapacity(256)
        for rowIndex in 0..<rowCount {
            guard getRow(at: rowIndex, into: &rowBuffer) else { continue }
            for cell in rowBuffer where cell.hasInlineImage {
                ids.insert(Int(cell.imageID))
            }
        }
        return ids
    }

    @discardableResult
    func compactIfUnderutilized() -> Bool {
        guard let rb = ringBuffer else { return false }
        flushRecentRowsToArchived()
        let didCompact = ring_buffer_compact(rb)
        if serializeBufCapacity > 0 {
            releaseSerializationBuffer()
        }
        return didCompact
    }

    func discardPersistentBackingStore() {
        guard persistentPath != nil else { return }
        clear()
        unlinkOnDeinit = true
    }

    private func releaseSerializationBuffer() {
        serializeBuf?.deallocate()
        serializeBuf = nil
        serializeBufCapacity = 0
    }

    private func resizeSerializationBuffer(requiredByteCount: Int) {
        let targetCapacity = Self.recommendedSerializationBufferCapacity(for: requiredByteCount)
        guard targetCapacity != serializeBufCapacity else { return }
        serializeBuf?.deallocate()
        serializeBuf = .allocate(capacity: targetCapacity)
        serializeBufCapacity = targetCapacity
    }

    private func shouldShrinkSerializationBuffer(requiredByteCount: Int) -> Bool {
        guard serializeBufCapacity > 0 else { return false }
        let recommended = Self.recommendedSerializationBufferCapacity(for: requiredByteCount)
        return serializeBufCapacity >= recommended * 2
    }

    private static func recommendedSerializationBufferCapacity(for requiredByteCount: Int) -> Int {
        let aligned = ((max(requiredByteCount, 1) + serializationBufferPageSize - 1) / serializationBufferPageSize) * serializationBufferPageSize
        return max(serializationBufferPageSize, aligned)
    }

    private static func serializedByteCount(forRow row: BufferedRow) -> Int {
        switch row.storage {
        case .encoded(let bytes):
            return bytes.count
        case .cells(let cells):
            let plan = encodingPlan(for: cells, cellCount: row.cellCount, hint: row.encodingHint)
            return serializedByteCount(for: plan, cellCount: row.cellCount)
        }
    }


    private static func encodeBufferedRowIfPossible(cells: ArraySlice<Cell>,
                                                    cellCount: Int,
                                                    hint: RowEncodingHint) -> [UInt8]? {
        let plan = encodingPlan(for: cells, cellCount: cellCount, hint: hint)
        switch plan {
        case .full:
            return nil
        case .compactDefault, .compactUniformAttributes:
            let byteCount = serializedByteCount(for: plan, cellCount: cellCount)
            var bytes = [UInt8](repeating: 0, count: byteCount)
            bytes.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                serializeRow(cells, cellCount: cellCount, using: plan, into: baseAddress)
            }
            return bytes
        }
    }

    private static func deserializeBufferedRow(encodedBytes ptr: UnsafePointer<UInt8>,
                                               length: Int,
                                               into destination: inout [Cell]) -> Bool {
        guard length > 0 else {
            destination.removeAll(keepingCapacity: true)
            return false
        }

        let cellCount: Int
        destination.removeAll(keepingCapacity: true)
        if Self.isCompactDefaultRowFormat(length: length, firstByte: ptr[0]) {
            let trimmed = ptr[0] == RowFormat.compactDefaultTrimmed
            let headerBytes = trimmed ? Self.compactTrimmedRowHeaderBytes : Self.compactRowHeaderBytes
            let serializedCount = (length - headerBytes) / MemoryLayout<UInt32>.size
            cellCount = trimmed ? Int(Self.deserializeUInt16(from: ptr + 1)) : serializedCount
            destination.reserveCapacity(cellCount)
            var offset = headerBytes
            for _ in 0..<serializedCount {
                destination.append(Self.deserializeCompactDefaultCell(from: ptr + offset))
                offset += MemoryLayout<UInt32>.size
            }
            if trimmed && cellCount > serializedCount {
                destination.append(contentsOf: repeatElement(Cell.empty, count: cellCount - serializedCount))
            }
        } else if Self.isCompactUniformAttributesRowFormat(length: length, firstByte: ptr[0]) {
            let trimmed = ptr[0] == RowFormat.compactUniformAttributesTrimmed
            let sharedAttributes = Self.deserializeAttributes(
                foregroundPtr: ptr + 1,
                backgroundPtr: ptr + 5,
                flags: ptr[9],
                underlineStyleRaw: ptr[10],
                underlineColorPtr: ptr + 11
            )
            let headerBytes = trimmed ? Self.uniformAttributesTrimmedHeaderBytes : Self.uniformAttributesHeaderBytes
            let serializedCount = (length - headerBytes) / Self.uniformAttributesBytesPerCell
            cellCount = trimmed ? Int(Self.deserializeUInt16(from: ptr + 15)) : serializedCount
            destination.reserveCapacity(cellCount)
            var offset = headerBytes
            for _ in 0..<serializedCount {
                destination.append(Self.deserializeCompactUniformAttributeCell(from: ptr + offset,
                                                                               sharedAttributes: sharedAttributes))
                offset += Self.uniformAttributesBytesPerCell
            }
            if trimmed && cellCount > serializedCount {
                let blank = Cell(
                    codepoint: Cell.empty.codepoint,
                    attributes: sharedAttributes,
                    width: Cell.empty.width,
                    isWideContinuation: false
                )
                destination.append(contentsOf: repeatElement(blank, count: cellCount - serializedCount))
            }
        } else {
            return false
        }
        return true
    }

    // MARK: - Cell Serialization

    /// Binary format per full cell (20 bytes):
    ///   [0..3]  codepoint (UInt32, little-endian)
    ///   [4]     fg_type (0=default, 1=indexed, 2=rgb)
    ///   [5]     fg_data1 (index or R)
    ///   [6]     fg_data2 (G)
    ///   [7]     fg_data3 (B)
    ///   [8]     bg_type
    ///   [9]     bg_data1
    ///   [10]    bg_data2
    ///   [11]    bg_data3
    ///   [12]    attr_flags (8 booleans packed into bits)
    ///   [13]    width
    ///   [14]    isWideContinuation
    ///   [15]    underline_style
    ///   [16]    underline_color_type
    ///   [17]    underline_color_data1
    ///   [18]    underline_color_data2
    ///   [19]    underline_color_data3
    ///   [20..23] image_id (UInt32, little-endian)
    ///   [24..25] image_columns (UInt16, little-endian)
    ///   [26..27] image_rows (UInt16, little-endian)
    ///   [28]     image_origin_col_offset
    ///   [29]     image_origin_row_offset
    ///   [30]     grapheme_tail_count
    ///   [31..58] grapheme tail scalars (7 * UInt32, little-endian)
    ///   [59]     reserved

    private static func serializeCell(_ cell: Cell, to ptr: UnsafeMutablePointer<UInt8>) {
        // Codepoint (little-endian)
        let cp = cell.codepoint
        ptr[0] = UInt8(cp & 0xFF)
        ptr[1] = UInt8((cp >> 8) & 0xFF)
        ptr[2] = UInt8((cp >> 16) & 0xFF)
        ptr[3] = UInt8((cp >> 24) & 0xFF)

        // Foreground color
        serializeColor(cell.attributes.foreground, to: ptr + 4)

        // Background color
        serializeColor(cell.attributes.background, to: ptr + 8)

        // Attribute flags
        ptr[12] = serializeAttributeFlags(cell.attributes)

        // Width and continuation
        ptr[13] = cell.width
        ptr[14] = cell.isWideContinuation ? 1 : 0
        ptr[15] = cell.attributes.underlineStyle.rawValue
        serializeColor(cell.attributes.underlineColor, to: ptr + 16)
        let imageID = cell.imageID
        ptr[20] = UInt8(imageID & 0xFF)
        ptr[21] = UInt8((imageID >> 8) & 0xFF)
        ptr[22] = UInt8((imageID >> 16) & 0xFF)
        ptr[23] = UInt8((imageID >> 24) & 0xFF)
        serializeUInt16(cell.imageColumns, to: ptr + 24)
        serializeUInt16(cell.imageRows, to: ptr + 26)
        ptr[28] = UInt8(truncatingIfNeeded: cell.imageOriginColOffset)
        ptr[29] = UInt8(truncatingIfNeeded: cell.imageOriginRowOffset)
        ptr[30] = cell.graphemeTailCount
        serializeCodepoint(cell.graphemeTail0, to: ptr + 31)
        serializeCodepoint(cell.graphemeTail1, to: ptr + 35)
        serializeCodepoint(cell.graphemeTail2, to: ptr + 39)
        serializeCodepoint(cell.graphemeTail3, to: ptr + 43)
        serializeCodepoint(cell.graphemeTail4, to: ptr + 47)
        serializeCodepoint(cell.graphemeTail5, to: ptr + 51)
        serializeCodepoint(cell.graphemeTail6, to: ptr + 55)
        ptr[59] = 0
    }

    private static func serializeColor(_ color: TerminalColor, to ptr: UnsafeMutablePointer<UInt8>) {
        switch color {
        case .default:
            ptr[0] = 0; ptr[1] = 0; ptr[2] = 0; ptr[3] = 0
        case .indexed(let idx):
            ptr[0] = 1; ptr[1] = idx; ptr[2] = 0; ptr[3] = 0
        case .rgb(let r, let g, let b):
            ptr[0] = 2; ptr[1] = r; ptr[2] = g; ptr[3] = b
        }
    }

    private static func encodingPlan(for cells: [Cell],
                                     cellCount: Int,
                                     hint: RowEncodingHint = .unknown) -> RowEncodingPlan {
        cells.withUnsafeBufferPointer { buffer in
            encodingPlan(for: buffer, cellCount: cellCount, hint: hint)
        }
    }

    private static func encodingPlan(for cells: ArraySlice<Cell>,
                                     cellCount: Int,
                                     hint: RowEncodingHint = .unknown) -> RowEncodingPlan {
        if let result = cells.withContiguousStorageIfAvailable({ storage in
            encodingPlan(
                for: UnsafeBufferPointer(start: storage.baseAddress, count: min(cellCount, storage.count)),
                cellCount: cellCount,
                hint: hint
            )
        }) {
            return result
        }
        return encodingPlan(for: Array(cells), cellCount: cellCount, hint: hint)
    }

    private static func encodingPlan(for cells: UnsafeBufferPointer<Cell>,
                                     cellCount: Int,
                                     hint: RowEncodingHint = .unknown) -> RowEncodingPlan {
        switch hint.kind {
        case .compactDefault(let serializedCount):
            return .compactDefault(serializedCount: min(serializedCount, cellCount))
        case .compactUniformAttributes(let sharedAttributes, let serializedCount):
            return .compactUniformAttributes(
                sharedAttributes: sharedAttributes,
                serializedCount: min(serializedCount, cellCount)
            )
        case .full:
            return .full
        case .unknown:
            break
        }

        guard let first = cells.first else { return .compactDefault(serializedCount: 0) }

        let sharedAttributes = first.attributes
        var canUseCompactDefault = true
        var canUseCompactUniform = true

        for cell in cells {
            if canUseCompactDefault && !isCompactDefaultCell(cell) {
                canUseCompactDefault = false
            }

            if canUseCompactUniform && !isCompactUniformAttributeCell(cell, sharedAttributes: sharedAttributes) {
                canUseCompactUniform = false
            }

            if !canUseCompactDefault && !canUseCompactUniform {
                return .full
            }
        }

        var compactDefaultSerializedCount = cellCount
        var compactUniformSerializedCount = cellCount
        if canUseCompactDefault || canUseCompactUniform {
            var sawCompactDefaultContent = false
            var sawCompactUniformContent = false
            var index = cellCount - 1
            for storageIndex in stride(from: cellCount - 1, through: 0, by: -1) {
                let cell = cells[storageIndex]
                if canUseCompactDefault {
                    if !sawCompactDefaultContent {
                        if isDefaultBlankCell(cell) {
                            compactDefaultSerializedCount = index
                        } else {
                            compactDefaultSerializedCount = index + 1
                            sawCompactDefaultContent = true
                        }
                    }
                }

                if canUseCompactUniform {
                    if !sawCompactUniformContent {
                        if isUniformBlankCell(cell, sharedAttributes: sharedAttributes) {
                            compactUniformSerializedCount = index
                        } else {
                            compactUniformSerializedCount = index + 1
                            sawCompactUniformContent = true
                        }
                    }
                }

                if (!canUseCompactDefault || sawCompactDefaultContent) &&
                    (!canUseCompactUniform || sawCompactUniformContent) {
                    break
                }
                if index == 0 { break }
                index -= 1
            }
        }

        if canUseCompactDefault {
            return .compactDefault(serializedCount: compactDefaultSerializedCount)
        }
        if canUseCompactUniform {
            return .compactUniformAttributes(
                sharedAttributes: sharedAttributes,
                serializedCount: compactUniformSerializedCount
            )
        }
        return .full
    }

    private static func serializedByteCount(for plan: RowEncodingPlan, cellCount: Int) -> Int {
        switch plan {
        case .compactDefault(let serializedCount):
            let headerBytes = serializedCount == cellCount
                ? compactRowHeaderBytes
                : compactTrimmedRowHeaderBytes
            return headerBytes + (serializedCount * MemoryLayout<UInt32>.size)
        case .compactUniformAttributes(_, let serializedCount):
            let headerBytes = serializedCount == cellCount
                ? uniformAttributesHeaderBytes
                : uniformAttributesTrimmedHeaderBytes
            return headerBytes + (serializedCount * uniformAttributesBytesPerCell)
        case .full:
            return cellCount * bytesPerCell
        }
    }

    private static func serializeRow(_ cells: [Cell],
                                     cellCount: Int,
                                     using encodingPlan: RowEncodingPlan,
                                     into buf: UnsafeMutablePointer<UInt8>) {
        cells.withUnsafeBufferPointer { buffer in
            serializeRow(buffer, cellCount: cellCount, using: encodingPlan, into: buf)
        }
    }

    private static func serializeRow(_ cells: ArraySlice<Cell>,
                                     cellCount: Int,
                                     using encodingPlan: RowEncodingPlan,
                                     into buf: UnsafeMutablePointer<UInt8>) {
        if let _ = cells.withContiguousStorageIfAvailable({ storage in
            serializeRow(
                UnsafeBufferPointer(start: storage.baseAddress, count: min(cellCount, storage.count)),
                cellCount: cellCount,
                using: encodingPlan,
                into: buf
            )
        }) {
            return
        }
        serializeRow(Array(cells), cellCount: cellCount, using: encodingPlan, into: buf)
    }

    private static func serializeRow(_ cells: UnsafeBufferPointer<Cell>,
                                     cellCount: Int,
                                     using encodingPlan: RowEncodingPlan,
                                     into buf: UnsafeMutablePointer<UInt8>) {
        switch encodingPlan {
        case .compactDefault(let serializedCount):
            let trimmed = serializedCount != cellCount
            buf[0] = trimmed ? RowFormat.compactDefaultTrimmed : RowFormat.compactDefault
            var offset = trimmed ? compactTrimmedRowHeaderBytes : compactRowHeaderBytes
            if trimmed {
                serializeUInt16(UInt16(cellCount), to: buf + 1)
            }
            precondition(cells.count >= serializedCount, "Compact default row missing serialized cells")
            for index in 0..<serializedCount {
                serializeCompactDefaultCell(cells[index], to: buf + offset)
                offset += MemoryLayout<UInt32>.size
            }
        case .compactUniformAttributes(let sharedAttributes, let serializedCount):
            let trimmed = serializedCount != cellCount
            buf[0] = trimmed ? RowFormat.compactUniformAttributesTrimmed : RowFormat.compactUniformAttributes
            serializeColor(sharedAttributes.foreground, to: buf + 1)
            serializeColor(sharedAttributes.background, to: buf + 5)
            buf[9] = serializeAttributeFlags(sharedAttributes)
            buf[10] = sharedAttributes.underlineStyle.rawValue
            serializeColor(sharedAttributes.underlineColor, to: buf + 11)
            var offset = trimmed ? uniformAttributesTrimmedHeaderBytes : uniformAttributesHeaderBytes
            if trimmed {
                serializeUInt16(UInt16(cellCount), to: buf + 15)
            }
            precondition(cells.count >= serializedCount, "Uniform row missing serialized cells")
            for index in 0..<serializedCount {
                serializeCompactUniformAttributeCell(cells[index], to: buf + offset)
                offset += uniformAttributesBytesPerCell
            }
        case .full:
            precondition(cells.count == cellCount, "Full row serialization requires all cells")
            var offset = 0
            for index in 0..<cellCount {
                serializeCell(cells[index], to: buf + offset)
                offset += bytesPerCell
            }
        }
    }

    private static func isCompactDefaultRowFormat(length: Int, firstByte: UInt8) -> Bool {
        guard length > compactRowHeaderBytes,
              length % bytesPerCell != 0,
              firstByte == RowFormat.compactDefault || firstByte == RowFormat.compactDefaultTrimmed else {
            return false
        }
        let headerBytes = firstByte == RowFormat.compactDefaultTrimmed
            ? compactTrimmedRowHeaderBytes
            : compactRowHeaderBytes
        return (length - headerBytes) % MemoryLayout<UInt32>.size == 0
    }

    private static func isCompactUniformAttributesRowFormat(length: Int, firstByte: UInt8) -> Bool {
        guard length > uniformAttributesHeaderBytes,
              firstByte == RowFormat.compactUniformAttributes ||
                firstByte == RowFormat.compactUniformAttributesTrimmed else {
            return false
        }
        let headerBytes = firstByte == RowFormat.compactUniformAttributesTrimmed
            ? uniformAttributesTrimmedHeaderBytes
            : uniformAttributesHeaderBytes
        return (length - headerBytes) % uniformAttributesBytesPerCell == 0
    }

    private static func isCell(_ cell: Cell, equalTo other: Cell) -> Bool {
        cell.codepoint == other.codepoint &&
        cell.attributes == other.attributes &&
        cell.width == other.width &&
        cell.isWideContinuation == other.isWideContinuation &&
        cell.imageID == other.imageID &&
        cell.imageColumns == other.imageColumns &&
        cell.imageRows == other.imageRows &&
        cell.imageOriginColOffset == other.imageOriginColOffset &&
        cell.imageOriginRowOffset == other.imageOriginRowOffset &&
        cell.graphemeTailCount == other.graphemeTailCount &&
        cell.graphemeTail0 == other.graphemeTail0 &&
        cell.graphemeTail1 == other.graphemeTail1 &&
        cell.graphemeTail2 == other.graphemeTail2 &&
        cell.graphemeTail3 == other.graphemeTail3 &&
        cell.graphemeTail4 == other.graphemeTail4 &&
        cell.graphemeTail5 == other.graphemeTail5 &&
        cell.graphemeTail6 == other.graphemeTail6
    }

    private static func isCompactDefaultCell(_ cell: Cell) -> Bool {
        !cell.hasInlineImage &&
        !cell.hasGraphemeTail &&
        cell.attributes == .default &&
        cell.width == 1 &&
        !cell.isWideContinuation
    }

    private static func isDefaultBlankCell(_ cell: Cell) -> Bool {
        cell.codepoint == Cell.empty.codepoint &&
        cell.attributes == Cell.empty.attributes &&
        cell.width == Cell.empty.width &&
        !cell.isWideContinuation &&
        !cell.hasInlineImage &&
        !cell.hasGraphemeTail
    }

    private static func isUniformBlankCell(_ cell: Cell, sharedAttributes: CellAttributes) -> Bool {
        cell.codepoint == Cell.empty.codepoint &&
        cell.attributes == sharedAttributes &&
        cell.width == Cell.empty.width &&
        !cell.isWideContinuation &&
        !cell.hasInlineImage &&
        !cell.hasGraphemeTail
    }

    private static func isCompactUniformAttributeCell(_ cell: Cell, sharedAttributes: CellAttributes) -> Bool {
        cell.attributes == sharedAttributes &&
        !cell.hasInlineImage &&
        !cell.hasGraphemeTail
    }

    private static func serializeUInt16(_ value: UInt16, to ptr: UnsafeMutablePointer<UInt8>) {
        ptr[0] = UInt8(value & 0xFF)
        ptr[1] = UInt8((value >> 8) & 0xFF)
    }

    private static func deserializeUInt16(from ptr: UnsafePointer<UInt8>) -> UInt16 {
        UInt16(ptr[0]) | (UInt16(ptr[1]) << 8)
    }

    private static func serializeCompactDefaultCell(_ cell: Cell, to ptr: UnsafeMutablePointer<UInt8>) {
        serializeCodepoint(cell.codepoint, to: ptr)
    }

    private static func serializeCompactUniformAttributeCell(_ cell: Cell, to ptr: UnsafeMutablePointer<UInt8>) {
        serializeCompactDefaultCell(cell, to: ptr)
        let widthBits = min(cell.width, 3)
        ptr[4] = widthBits | (cell.isWideContinuation ? 0x80 : 0)
    }

    private static func serializeAttributeFlags(_ attributes: CellAttributes) -> UInt8 {
        var flags: UInt8 = 0
        if attributes.bold          { flags |= 0x01 }
        if attributes.italic        { flags |= 0x02 }
        if attributes.underline     { flags |= 0x04 }
        if attributes.strikethrough { flags |= 0x08 }
        if attributes.inverse       { flags |= 0x10 }
        if attributes.hidden        { flags |= 0x20 }
        if attributes.dim           { flags |= 0x40 }
        if attributes.blink         { flags |= 0x80 }
        return flags
    }

    private static func deserializeCell(from ptr: UnsafePointer<UInt8>) -> Cell {
        let codepoint = deserializeCodepoint(from: ptr)

        let attrs = deserializeAttributes(foregroundPtr: ptr + 4,
                                          backgroundPtr: ptr + 8,
                                          flags: ptr[12],
                                          underlineStyleRaw: ptr[15],
                                          underlineColorPtr: ptr + 16)

        return Cell(
            codepoint: codepoint,
            attributes: attrs,
            width: ptr[13],
            isWideContinuation: ptr[14] != 0,
            imageID: deserializeCodepoint(from: ptr + 20),
            imageColumns: deserializeUInt16(from: ptr + 24),
            imageRows: deserializeUInt16(from: ptr + 26),
            imageOriginColOffset: UInt16(ptr[28]),
            imageOriginRowOffset: UInt16(ptr[29]),
            graphemeTailCount: ptr[30],
            graphemeTail0: deserializeCodepoint(from: ptr + 31),
            graphemeTail1: deserializeCodepoint(from: ptr + 35),
            graphemeTail2: deserializeCodepoint(from: ptr + 39),
            graphemeTail3: deserializeCodepoint(from: ptr + 43),
            graphemeTail4: deserializeCodepoint(from: ptr + 47),
            graphemeTail5: deserializeCodepoint(from: ptr + 51),
            graphemeTail6: deserializeCodepoint(from: ptr + 55)
        )
    }

    private static func deserializeCompactDefaultCell(from ptr: UnsafePointer<UInt8>) -> Cell {
        let codepoint = deserializeCodepoint(from: ptr)
        return Cell(
            codepoint: codepoint,
            attributes: .default,
            width: 1,
            isWideContinuation: false
        )
    }

    private static func deserializeCompactUniformAttributeCell(
        from ptr: UnsafePointer<UInt8>,
        sharedAttributes: CellAttributes
    ) -> Cell {
        let codepoint = deserializeCodepoint(from: ptr)
        let meta = ptr[4]
        return Cell(
            codepoint: codepoint,
            attributes: sharedAttributes,
            width: meta & 0x03,
            isWideContinuation: (meta & 0x80) != 0
        )
    }

    private static func deserializeCodepoint(from ptr: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(ptr[0])
            | (UInt32(ptr[1]) << 8)
            | (UInt32(ptr[2]) << 16)
            | (UInt32(ptr[3]) << 24)
    }

    private static func serializeCodepoint(_ codepoint: UInt32, to ptr: UnsafeMutablePointer<UInt8>) {
        ptr[0] = UInt8(codepoint & 0xFF)
        ptr[1] = UInt8((codepoint >> 8) & 0xFF)
        ptr[2] = UInt8((codepoint >> 16) & 0xFF)
        ptr[3] = UInt8((codepoint >> 24) & 0xFF)
    }

    private static func deserializeAttributes(
        foregroundPtr: UnsafePointer<UInt8>,
        backgroundPtr: UnsafePointer<UInt8>,
        flags: UInt8,
        underlineStyleRaw: UInt8 = 0,
        underlineColorPtr: UnsafePointer<UInt8>? = nil
    ) -> CellAttributes {
        CellAttributes(
            foreground: deserializeColor(from: foregroundPtr),
            background: deserializeColor(from: backgroundPtr),
            bold:          flags & 0x01 != 0,
            italic:        flags & 0x02 != 0,
            underline:     flags & 0x04 != 0,
            strikethrough: flags & 0x08 != 0,
            inverse:       flags & 0x10 != 0,
            hidden:        flags & 0x20 != 0,
            dim:           flags & 0x40 != 0,
            blink:         flags & 0x80 != 0,
            underlineStyle: UnderlineStyle(rawValue: underlineStyleRaw) ?? .single,
            underlineColor: underlineColorPtr.map(deserializeColor(from:)) ?? .default
        )
    }

    private static func deserializeColor(from ptr: UnsafePointer<UInt8>) -> TerminalColor {
        switch ptr[0] {
        case 1: return .indexed(ptr[1])
        case 2: return .rgb(ptr[1], ptr[2], ptr[3])
        default: return .default
        }
    }
}

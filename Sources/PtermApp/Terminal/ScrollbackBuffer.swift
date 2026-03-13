import Foundation
import PtermCore

/// Swift wrapper around the C ring buffer for terminal scrollback storage.
///
/// Serializes Cell arrays to a compact binary format (16 bytes per cell)
/// and stores them in the circular ring buffer. When the buffer is full,
/// the oldest rows are automatically evicted.
///
/// Thread safety: Callers must manage external synchronization.
/// In practice, the TerminalController lock covers all access.
final class ScrollbackBuffer {
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

    /// Number of rows currently stored
    var rowCount: Int {
        guard let rb = ringBuffer else { return 0 }
        return Int(ring_buffer_row_count(rb))
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

    var serializationBufferCapacity: Int {
        serializeBufCapacity
    }

    /// Reusable serialization buffer (avoids per-call allocation)
    private var serializeBuf: UnsafeMutablePointer<UInt8>?
    private var serializeBufCapacity: Int = 0
    private static let serializationBufferPageSize = 4096

    /// Bytes per cell in binary format
    static let bytesPerCell = 16
    private static let compactRowHeaderBytes = 1
    private static let compactTrimmedRowHeaderBytes = 3
    private static let uniformAttributesHeaderBytes = 10
    private static let uniformAttributesTrimmedHeaderBytes = 12
    private static let uniformAttributesBytesPerCell = 5

    init(initialCapacity: Int = 64 * 1024 * 1024,
         maxCapacity: Int = 64 * 1024 * 1024,
         persistentPath: String? = nil) {
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
    }

    deinit {
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
    func appendRow(_ cells: ArraySlice<Cell>, isWrapped: Bool) {
        guard let rb = ringBuffer else { return }

        let cellCount = cells.count
        let usesCompactDefaultFormat = Self.canUseCompactDefaultRowFormat(for: cells)
        let usesCompactUniformAttributesFormat = !usesCompactDefaultFormat &&
            Self.canUseCompactUniformAttributesRowFormat(for: cells)
        let compactDefaultSerializedCount = usesCompactDefaultFormat
            ? Self.trimmedCompactDefaultCellCount(for: cells)
            : 0
        let compactUniformSerializedCount = usesCompactUniformAttributesFormat
            ? Self.trimmedCompactUniformCellCount(for: cells)
            : 0
        let byteCount: Int
        if usesCompactDefaultFormat {
            let headerBytes = compactDefaultSerializedCount == cellCount
                ? Self.compactRowHeaderBytes
                : Self.compactTrimmedRowHeaderBytes
            byteCount = headerBytes + (compactDefaultSerializedCount * MemoryLayout<UInt32>.size)
        } else if usesCompactUniformAttributesFormat {
            let headerBytes = compactUniformSerializedCount == cellCount
                ? Self.uniformAttributesHeaderBytes
                : Self.uniformAttributesTrimmedHeaderBytes
            byteCount = headerBytes + (compactUniformSerializedCount * Self.uniformAttributesBytesPerCell)
        } else {
            byteCount = cellCount * Self.bytesPerCell
        }

        // Ensure serialization buffer is large enough while bounding retained slack.
        if serializeBufCapacity < byteCount || shouldShrinkSerializationBuffer(requiredByteCount: byteCount) {
            resizeSerializationBuffer(requiredByteCount: byteCount)
        }

        guard let buf = serializeBuf else { return }

        // Serialize cells into the buffer
        if usesCompactDefaultFormat {
            let trimmed = compactDefaultSerializedCount != cellCount
            buf[0] = trimmed ? RowFormat.compactDefaultTrimmed : RowFormat.compactDefault
            var offset = trimmed ? Self.compactTrimmedRowHeaderBytes : Self.compactRowHeaderBytes
            if trimmed {
                Self.serializeUInt16(UInt16(cellCount), to: buf + 1)
            }
            for cell in cells.prefix(compactDefaultSerializedCount) {
                Self.serializeCompactDefaultCell(cell, to: buf + offset)
                offset += MemoryLayout<UInt32>.size
            }
        } else if usesCompactUniformAttributesFormat {
            let trimmed = compactUniformSerializedCount != cellCount
            buf[0] = trimmed ? RowFormat.compactUniformAttributesTrimmed : RowFormat.compactUniformAttributes
            let sharedAttributes = cells.first?.attributes ?? .default
            Self.serializeColor(sharedAttributes.foreground, to: buf + 1)
            Self.serializeColor(sharedAttributes.background, to: buf + 5)
            buf[9] = Self.serializeAttributeFlags(sharedAttributes)
            var offset = trimmed ? Self.uniformAttributesTrimmedHeaderBytes : Self.uniformAttributesHeaderBytes
            if trimmed {
                Self.serializeUInt16(UInt16(cellCount), to: buf + 10)
            }
            for cell in cells.prefix(compactUniformSerializedCount) {
                Self.serializeCompactUniformAttributeCell(cell, to: buf + offset)
                offset += Self.uniformAttributesBytesPerCell
            }
        } else {
            var offset = 0
            for cell in cells {
                Self.serializeCell(cell, to: buf + offset)
                offset += Self.bytesPerCell
            }
        }

        _ = ring_buffer_append_row(rb, buf, UInt32(byteCount), isWrapped)
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
                flags: ptr[9]
            )
            let headerBytes = trimmed ? Self.uniformAttributesTrimmedHeaderBytes : Self.uniformAttributesHeaderBytes
            let serializedCount = (Int(length) - headerBytes) / Self.uniformAttributesBytesPerCell
            cellCount = trimmed ? Int(Self.deserializeUInt16(from: ptr + 10)) : serializedCount
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
        guard let rb = ringBuffer else { return false }
        var continuation: Bool = false
        guard ring_buffer_get_row(rb, UInt32(rowIndex), nil, nil, &continuation) else {
            return false
        }
        return continuation
    }

    /// Clear all scrollback data.
    func clear() {
        guard let rb = ringBuffer else { return }
        ring_buffer_clear(rb)
        releaseSerializationBuffer()
    }

    @discardableResult
    func compactIfUnderutilized() -> Bool {
        guard let rb = ringBuffer else { return false }
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

    // MARK: - Cell Serialization

    /// Binary format per cell (16 bytes):
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
    ///   [15]    reserved

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
        ptr[15] = 0
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

    private static func canUseCompactDefaultRowFormat(for cells: ArraySlice<Cell>) -> Bool {
        for cell in cells {
            guard cell.attributes == .default,
                  cell.width == 1,
                  !cell.isWideContinuation else {
                return false
            }
        }
        return true
    }

    private static func canUseCompactUniformAttributesRowFormat(for cells: ArraySlice<Cell>) -> Bool {
        guard let sharedAttributes = cells.first?.attributes else {
            return false
        }
        for cell in cells {
            guard cell.attributes == sharedAttributes else {
                return false
            }
        }
        return true
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

    private static func trimmedCompactDefaultCellCount(for cells: ArraySlice<Cell>) -> Int {
        trimTrailingCellCount(for: cells) { cell in
            isCell(cell, equalTo: .empty)
        }
    }

    private static func trimmedCompactUniformCellCount(for cells: ArraySlice<Cell>) -> Int {
        guard let sharedAttributes = cells.first?.attributes else { return 0 }
        let blank = Cell(
            codepoint: Cell.empty.codepoint,
            attributes: sharedAttributes,
            width: Cell.empty.width,
            isWideContinuation: false
        )
        return trimTrailingCellCount(for: cells) { cell in
            isCell(cell, equalTo: blank)
        }
    }

    private static func isCell(_ cell: Cell, equalTo other: Cell) -> Bool {
        cell.codepoint == other.codepoint &&
        cell.attributes == other.attributes &&
        cell.width == other.width &&
        cell.isWideContinuation == other.isWideContinuation
    }

    private static func trimTrailingCellCount(
        for cells: ArraySlice<Cell>,
        isTrimmable: (Cell) -> Bool
    ) -> Int {
        var keptCount = cells.count
        for cell in cells.reversed() {
            guard isTrimmable(cell) else { break }
            keptCount -= 1
        }
        return max(0, keptCount)
    }

    private static func serializeUInt16(_ value: UInt16, to ptr: UnsafeMutablePointer<UInt8>) {
        ptr[0] = UInt8(value & 0xFF)
        ptr[1] = UInt8((value >> 8) & 0xFF)
    }

    private static func deserializeUInt16(from ptr: UnsafePointer<UInt8>) -> UInt16 {
        UInt16(ptr[0]) | (UInt16(ptr[1]) << 8)
    }

    private static func serializeCompactDefaultCell(_ cell: Cell, to ptr: UnsafeMutablePointer<UInt8>) {
        let cp = cell.codepoint
        ptr[0] = UInt8(cp & 0xFF)
        ptr[1] = UInt8((cp >> 8) & 0xFF)
        ptr[2] = UInt8((cp >> 16) & 0xFF)
        ptr[3] = UInt8((cp >> 24) & 0xFF)
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
        let codepoint = UInt32(ptr[0])
            | (UInt32(ptr[1]) << 8)
            | (UInt32(ptr[2]) << 16)
            | (UInt32(ptr[3]) << 24)

        let attrs = deserializeAttributes(foregroundPtr: ptr + 4,
                                          backgroundPtr: ptr + 8,
                                          flags: ptr[12])

        return Cell(
            codepoint: codepoint,
            attributes: attrs,
            width: ptr[13],
            isWideContinuation: ptr[14] != 0
        )
    }

    private static func deserializeCompactDefaultCell(from ptr: UnsafePointer<UInt8>) -> Cell {
        let codepoint = UInt32(ptr[0])
            | (UInt32(ptr[1]) << 8)
            | (UInt32(ptr[2]) << 16)
            | (UInt32(ptr[3]) << 24)
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
        let codepoint = UInt32(ptr[0])
            | (UInt32(ptr[1]) << 8)
            | (UInt32(ptr[2]) << 16)
            | (UInt32(ptr[3]) << 24)
        let meta = ptr[4]
        return Cell(
            codepoint: codepoint,
            attributes: sharedAttributes,
            width: meta & 0x03,
            isWideContinuation: (meta & 0x80) != 0
        )
    }

    private static func deserializeAttributes(
        foregroundPtr: UnsafePointer<UInt8>,
        backgroundPtr: UnsafePointer<UInt8>,
        flags: UInt8
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
            blink:         flags & 0x80 != 0
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

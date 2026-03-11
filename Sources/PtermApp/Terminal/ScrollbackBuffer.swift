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

    /// Reusable serialization buffer (avoids per-call allocation)
    private var serializeBuf: UnsafeMutablePointer<UInt8>?
    private var serializeBufCapacity: Int = 0

    /// Bytes per cell in binary format
    static let bytesPerCell = 16

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
        let byteCount = cellCount * Self.bytesPerCell

        // Ensure serialization buffer is large enough
        if serializeBufCapacity < byteCount {
            serializeBuf?.deallocate()
            serializeBufCapacity = byteCount + byteCount / 2
            serializeBuf = .allocate(capacity: serializeBufCapacity)
        }

        guard let buf = serializeBuf else { return }

        // Serialize cells into the buffer
        var offset = 0
        for cell in cells {
            Self.serializeCell(cell, to: buf + offset)
            offset += Self.bytesPerCell
        }

        _ = ring_buffer_append_row(rb, buf, UInt32(byteCount), isWrapped)
    }

    /// Get a row of cells from the scrollback buffer.
    /// rowIndex 0 = oldest row.
    /// Returns nil if the row doesn't exist.
    func getRow(at rowIndex: Int) -> [Cell]? {
        guard let rb = ringBuffer else { return nil }

        var dataPtr: UnsafePointer<UInt8>?
        var length: UInt32 = 0
        var continuation: Bool = false

        guard ring_buffer_get_row(rb, UInt32(rowIndex), &dataPtr, &length, &continuation) else {
            return nil
        }

        guard let ptr = dataPtr, length > 0 else { return nil }

        let cellCount = Int(length) / Self.bytesPerCell
        var cells = [Cell]()
        cells.reserveCapacity(cellCount)

        for i in 0..<cellCount {
            cells.append(Self.deserializeCell(from: ptr + i * Self.bytesPerCell))
        }

        return cells
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
    }

    func discardPersistentBackingStore() {
        guard persistentPath != nil else { return }
        clear()
        unlinkOnDeinit = true
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
        var flags: UInt8 = 0
        if cell.attributes.bold          { flags |= 0x01 }
        if cell.attributes.italic        { flags |= 0x02 }
        if cell.attributes.underline     { flags |= 0x04 }
        if cell.attributes.strikethrough { flags |= 0x08 }
        if cell.attributes.inverse       { flags |= 0x10 }
        if cell.attributes.hidden        { flags |= 0x20 }
        if cell.attributes.dim           { flags |= 0x40 }
        if cell.attributes.blink         { flags |= 0x80 }
        ptr[12] = flags

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

    private static func deserializeCell(from ptr: UnsafePointer<UInt8>) -> Cell {
        let codepoint = UInt32(ptr[0])
            | (UInt32(ptr[1]) << 8)
            | (UInt32(ptr[2]) << 16)
            | (UInt32(ptr[3]) << 24)

        let fg = deserializeColor(from: ptr + 4)
        let bg = deserializeColor(from: ptr + 8)

        let flags = ptr[12]
        let attrs = CellAttributes(
            foreground: fg,
            background: bg,
            bold:          flags & 0x01 != 0,
            italic:        flags & 0x02 != 0,
            underline:     flags & 0x04 != 0,
            strikethrough: flags & 0x08 != 0,
            inverse:       flags & 0x10 != 0,
            hidden:        flags & 0x20 != 0,
            dim:           flags & 0x40 != 0,
            blink:         flags & 0x80 != 0
        )

        return Cell(
            codepoint: codepoint,
            attributes: attrs,
            width: ptr[13],
            isWideContinuation: ptr[14] != 0
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

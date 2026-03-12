import Foundation
import XCTest
import PtermCore

final class RingBufferTests: XCTestCase {
    func testAppendAndReadRowsPreservesOrderAndContinuationFlags() {
        let rb = ring_buffer_create_sized(64, 64)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        let row1: [UInt8] = [1, 2, 3]
        let row2: [UInt8] = [4, 5]
        row1.withUnsafeBufferPointer { pointer in
            XCTAssertGreaterThanOrEqual(ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false), 0)
        }
        row2.withUnsafeBufferPointer { pointer in
            XCTAssertGreaterThanOrEqual(ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), true), 0)
        }

        XCTAssertEqual(ring_buffer_row_count(rb), 2)

        var dataPtr: UnsafePointer<UInt8>?
        var length: UInt32 = 0
        var continuation = false
        XCTAssertTrue(ring_buffer_get_row(rb, 0, &dataPtr, &length, &continuation))
        XCTAssertEqual(length, 3)
        XCTAssertFalse(continuation)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: dataPtr, count: Int(length))), row1)

        XCTAssertTrue(ring_buffer_get_row(rb, 1, &dataPtr, &length, &continuation))
        XCTAssertEqual(length, 2)
        XCTAssertTrue(continuation)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: dataPtr, count: Int(length))), row2)
    }

    func testBufferEvictsOldestRowsWhenCapacityExceeded() {
        let rb = ring_buffer_create_sized(8, 8)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        for value in 0..<4 {
            let row: [UInt8] = Array(repeating: UInt8(value), count: 4)
            row.withUnsafeBufferPointer { pointer in
                _ = ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false)
            }
        }

        XCTAssertEqual(ring_buffer_row_count(rb), 2)

        var dataPtr: UnsafePointer<UInt8>?
        var length: UInt32 = 0
        XCTAssertTrue(ring_buffer_get_row(rb, 0, &dataPtr, &length, nil))
        XCTAssertEqual(Array(UnsafeBufferPointer(start: dataPtr, count: Int(length))), [2, 2, 2, 2])
        XCTAssertTrue(ring_buffer_get_row(rb, 1, &dataPtr, &length, nil))
        XCTAssertEqual(Array(UnsafeBufferPointer(start: dataPtr, count: Int(length))), [3, 3, 3, 3])
    }

    func testClearRemovesAllRowsAndBytes() {
        let rb = ring_buffer_create_sized(32, 32)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        let row: [UInt8] = [1, 2, 3, 4]
        row.withUnsafeBufferPointer { pointer in
            _ = ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false)
        }
        XCTAssertGreaterThan(ring_buffer_bytes_used(rb), 0)

        ring_buffer_clear(rb)
        XCTAssertEqual(ring_buffer_row_count(rb), 0)
        XCTAssertEqual(ring_buffer_bytes_used(rb), 0)
    }

    func testAppendFailsWhenSingleRowExceedsMaxCapacity() {
        let rb = ring_buffer_create_sized(8, 16)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        let row: [UInt8] = Array(repeating: 1, count: 32)
        let result = row.withUnsafeBufferPointer {
            ring_buffer_append_row(rb, $0.baseAddress, UInt32($0.count), false)
        }

        XCTAssertEqual(result, -1)
        XCTAssertEqual(ring_buffer_row_count(rb), 0)
    }

    func testBufferGrowsBeyondInitialCapacityWhenNeeded() {
        let rb = ring_buffer_create_sized(8, 64)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        let row: [UInt8] = Array(repeating: 7, count: 20)
        row.withUnsafeBufferPointer { pointer in
            XCTAssertGreaterThanOrEqual(ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false), 0)
        }

        XCTAssertGreaterThan(ring_buffer_capacity(rb), 8)
        XCTAssertLessThanOrEqual(ring_buffer_capacity(rb), 64)
    }

    func testRowIndexGrowsForManySmallRowsWithoutEarlyEviction() {
        let rb = ring_buffer_create_sized(64, 64)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        let initialRowCapacity = ring_buffer_row_index_capacity(rb)
        XCTAssertGreaterThan(initialRowCapacity, 0)

        let row: [UInt8] = [7]
        for _ in 0..<(Int(initialRowCapacity) + 8) {
            row.withUnsafeBufferPointer { pointer in
                XCTAssertGreaterThanOrEqual(ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false), 0)
            }
        }

        XCTAssertEqual(ring_buffer_row_count(rb), initialRowCapacity + 8)
        XCTAssertGreaterThan(ring_buffer_row_index_capacity(rb), initialRowCapacity)
        XCTAssertEqual(ring_buffer_bytes_used(rb), size_t(ring_buffer_row_count(rb)))
    }

    func testClearShrinksHeapBufferBackToInitialCapacity() {
        let rb = ring_buffer_create_sized(8, 64)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        let row: [UInt8] = Array(repeating: 1, count: 20)
        row.withUnsafeBufferPointer { pointer in
            _ = ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false)
        }
        XCTAssertEqual(ring_buffer_capacity(rb), 32)

        ring_buffer_clear(rb)

        XCTAssertEqual(ring_buffer_capacity(rb), 8)
        XCTAssertEqual(ring_buffer_row_count(rb), 0)
        XCTAssertEqual(ring_buffer_bytes_used(rb), 0)
    }

    func testClearShrinksHeapRowIndexBackToInitialCapacity() {
        let rb = ring_buffer_create_sized(64, 64)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        let initialRowCapacity = ring_buffer_row_index_capacity(rb)
        let row: [UInt8] = [2]
        for _ in 0..<(Int(initialRowCapacity) + 8) {
            row.withUnsafeBufferPointer { pointer in
                _ = ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false)
            }
        }
        XCTAssertGreaterThan(ring_buffer_row_index_capacity(rb), initialRowCapacity)

        ring_buffer_clear(rb)

        XCTAssertEqual(ring_buffer_row_index_capacity(rb), initialRowCapacity)
        XCTAssertEqual(ring_buffer_row_count(rb), 0)
    }

    func testLowUsageAppendPathShrinksBufferAfterPeakUsageDrops() {
        let rb = ring_buffer_create_sized(8, 64)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        let largeRow: [UInt8] = Array(repeating: 9, count: 61)
        largeRow.withUnsafeBufferPointer { pointer in
            XCTAssertGreaterThanOrEqual(ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false), 0)
        }
        XCTAssertEqual(ring_buffer_capacity(rb), 64)

        let smallRow: [UInt8] = [1]
        for _ in 0..<4 {
            smallRow.withUnsafeBufferPointer { pointer in
                XCTAssertGreaterThanOrEqual(ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false), 0)
            }
        }

        XCTAssertEqual(ring_buffer_capacity(rb), 32)
        XCTAssertEqual(ring_buffer_row_count(rb), 4)
        XCTAssertEqual(ring_buffer_bytes_used(rb), 4)
    }

    func testLowUsageAppendPathShrinksRowIndexAfterPeakRowCountDrops() {
        let rb = ring_buffer_create_sized(64, 64)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        let initialRowCapacity = ring_buffer_row_index_capacity(rb)
        let singleByteRow: [UInt8] = [1]
        for _ in 0..<(Int(initialRowCapacity) + 16) {
            singleByteRow.withUnsafeBufferPointer { pointer in
                XCTAssertGreaterThanOrEqual(ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false), 0)
            }
        }
        XCTAssertGreaterThan(ring_buffer_row_index_capacity(rb), initialRowCapacity)

        ring_buffer_clear(rb)
        XCTAssertEqual(ring_buffer_row_index_capacity(rb), initialRowCapacity)

        let largeRow: [UInt8] = Array(repeating: 9, count: 61)
        largeRow.withUnsafeBufferPointer { pointer in
            XCTAssertGreaterThanOrEqual(ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false), 0)
        }
        for _ in 0..<4 {
            singleByteRow.withUnsafeBufferPointer { pointer in
                XCTAssertGreaterThanOrEqual(ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false), 0)
            }
        }

        XCTAssertEqual(ring_buffer_row_count(rb), 4)
        XCTAssertEqual(ring_buffer_row_index_capacity(rb), initialRowCapacity)
    }

    func testMmapBackedBufferPersistsRowsAcrossReopen() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let path = tempRoot.appendingPathComponent("scrollback.bin").path
        do {
            let rb = ring_buffer_create_mmap_sized(path, 64, 64)
            XCTAssertNotNil(rb)
            defer { ring_buffer_destroy(rb) }

            let row: [UInt8] = [9, 8, 7]
            row.withUnsafeBufferPointer { pointer in
                _ = ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), true)
            }
        }

        let reopened = ring_buffer_create_mmap_sized(path, 64, 64)
        XCTAssertNotNil(reopened)
        defer { ring_buffer_destroy(reopened) }

        var dataPtr: UnsafePointer<UInt8>?
        var length: UInt32 = 0
        var continuation = false
        XCTAssertTrue(ring_buffer_get_row(reopened, 0, &dataPtr, &length, &continuation))
        XCTAssertEqual(Array(UnsafeBufferPointer(start: dataPtr, count: Int(length))), [9, 8, 7])
        XCTAssertTrue(continuation)
    }

    func testDestroyAndUnlinkRemovesMmapBackingFile() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let path = tempRoot.appendingPathComponent("scrollback.bin").path
        let rb = ring_buffer_create_mmap_sized(path, 64, 64)
        XCTAssertNotNil(rb)

        ring_buffer_destroy_and_unlink(rb)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testClearShrinksMmapBufferBackToInitialCapacity() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let path = tempRoot.appendingPathComponent("scrollback.bin").path
        let rb = ring_buffer_create_mmap_sized(path, 8, 64)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        let row: [UInt8] = Array(repeating: 4, count: 20)
        row.withUnsafeBufferPointer { pointer in
            _ = ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false)
        }
        XCTAssertEqual(ring_buffer_capacity(rb), 32)

        ring_buffer_clear(rb)

        XCTAssertEqual(ring_buffer_capacity(rb), 8)
        XCTAssertEqual(ring_buffer_row_count(rb), 0)
        XCTAssertEqual(ring_buffer_bytes_used(rb), 0)
    }

    func testMmapBackedRowIndexGrowthPersistsAcrossReopen() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let path = tempRoot.appendingPathComponent("scrollback.bin").path
        let initialRowCapacity: UInt32
        do {
            let rb = ring_buffer_create_mmap_sized(path, 64, 64)
            XCTAssertNotNil(rb)
            defer { ring_buffer_destroy(rb) }

            initialRowCapacity = ring_buffer_row_index_capacity(rb)
            let row: [UInt8] = [3]
            for _ in 0..<(Int(initialRowCapacity) + 8) {
                row.withUnsafeBufferPointer { pointer in
                    XCTAssertGreaterThanOrEqual(ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false), 0)
                }
            }
            XCTAssertGreaterThan(ring_buffer_row_index_capacity(rb), initialRowCapacity)
        }

        let reopened = ring_buffer_create_mmap_sized(path, 64, 64)
        XCTAssertNotNil(reopened)
        defer { ring_buffer_destroy(reopened) }

        XCTAssertGreaterThan(ring_buffer_row_index_capacity(reopened), initialRowCapacity)
        XCTAssertEqual(ring_buffer_row_count(reopened), initialRowCapacity + 8)
    }

    func testClearShrinksMmapRowIndexBackToInitialCapacity() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let path = tempRoot.appendingPathComponent("scrollback.bin").path
        let rb = ring_buffer_create_mmap_sized(path, 64, 64)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        let initialRowCapacity = ring_buffer_row_index_capacity(rb)
        let row: [UInt8] = [5]
        for _ in 0..<(Int(initialRowCapacity) + 8) {
            row.withUnsafeBufferPointer { pointer in
                _ = ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false)
            }
        }
        XCTAssertGreaterThan(ring_buffer_row_index_capacity(rb), initialRowCapacity)

        ring_buffer_clear(rb)

        XCTAssertEqual(ring_buffer_row_index_capacity(rb), initialRowCapacity)
        XCTAssertEqual(ring_buffer_row_count(rb), 0)
    }

    func testGetRowReturnsFalseForOutOfRangeIndex() {
        let rb = ring_buffer_create_sized(64, 64)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        var dataPtr: UnsafePointer<UInt8>?
        var length: UInt32 = 0
        XCTAssertFalse(ring_buffer_get_row(rb, 0, &dataPtr, &length, nil))
    }

    func testAppendZeroLengthRowIsRejected() {
        let rb = ring_buffer_create_sized(64, 64)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        XCTAssertEqual(ring_buffer_append_row(rb, nil, 0, false), -1)
        XCTAssertEqual(ring_buffer_row_count(rb), 0)
    }
}

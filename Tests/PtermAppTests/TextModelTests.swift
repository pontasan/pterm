import XCTest
@testable import PtermApp

final class TextModelTests: XCTestCase {
    func testCharacterWidthClassifiesASCIICJKCombiningEmojiAndControl() {
        XCTAssertEqual(CharacterWidth.width(of: 0x41), 1)
        XCTAssertEqual(CharacterWidth.width(of: 0x3042), 2)
        XCTAssertEqual(CharacterWidth.width(of: 0x0301), 0)
        XCTAssertEqual(CharacterWidth.width(of: 0x1F600), 2)
        XCTAssertEqual(CharacterWidth.width(of: 0x0A), -1)
    }

    func testTerminalColorResolveSupportsDefaultIndexedCubeGrayscaleAndRGB() {
        XCTAssertEqual(TerminalColor.default.resolve(isForeground: true).r, 0.8, accuracy: 0.001)
        XCTAssertEqual(TerminalColor.default.resolve(isForeground: false).r, 0.0, accuracy: 0.001)

        let ansi = TerminalColor.indexed(1).resolve(isForeground: true)
        XCTAssertGreaterThan(ansi.r, 0.7)
        XCTAssertLessThan(ansi.g, 0.3)

        let cube = TerminalColor.indexed(46).resolve(isForeground: true)
        XCTAssertGreaterThan(cube.g, 0.7)

        let gray = TerminalColor.indexed(244).resolve(isForeground: true)
        XCTAssertEqual(gray.r, gray.g, accuracy: 0.001)
        XCTAssertEqual(gray.g, gray.b, accuracy: 0.001)

        let rgb = TerminalColor.rgb(10, 20, 30).resolve(isForeground: true)
        XCTAssertEqual(rgb.r, Float(10.0 / 255.0), accuracy: 0.001)
        XCTAssertEqual(rgb.g, Float(20.0 / 255.0), accuracy: 0.001)
        XCTAssertEqual(rgb.b, Float(30.0 / 255.0), accuracy: 0.001)
    }

    func testTerminalTextEncodingRoundTripsUTF8AndUTF16() throws {
        let sample = "abc日本語😀"
        for encoding in [TerminalTextEncoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian] {
            let encoded = try XCTUnwrap(encoding.encode(sample))
            XCTAssertEqual(encoding.decode(encoded), sample)
        }
    }

    func testTerminalTextEncodingConfiguredValueNormalization() {
        XCTAssertEqual(TerminalTextEncoding(configuredValue: "UTF8"), .utf8)
        XCTAssertEqual(TerminalTextEncoding(configuredValue: "utf_16"), .utf16)
        XCTAssertEqual(TerminalTextEncoding(configuredValue: "utf16le"), .utf16LittleEndian)
        XCTAssertEqual(TerminalTextEncoding(configuredValue: "utf-16be"), .utf16BigEndian)
        XCTAssertNil(TerminalTextEncoding(configuredValue: "shift-jis"))
    }

    func testTerminalTextEncodingStringUsesReplacementCharacterForInvalidScalar() {
        let string = TerminalTextEncoding.string(from: [0x41, 0x110000, 0x42])
        XCTAssertEqual(string, "A\u{FFFD}B")
    }

    func testTerminalTextDecoderHandlesSplitUTF16Surrogates() {
        let decoder = TerminalTextDecoder(encoding: .utf16LittleEndian)
        var output = [UInt32](repeating: 0, count: 4)

        let firstChunk = Data([0x3D, 0xD8])
        let secondChunk = Data([0x00, 0xDE, 0x41, 0x00])

        let firstCount = firstChunk.withUnsafeBytes { rawBuffer in
            decoder.decode(rawBuffer.bindMemory(to: UInt8.self), into: &output)
        }
        XCTAssertEqual(firstCount, 0)

        let secondCount = secondChunk.withUnsafeBytes { rawBuffer in
            decoder.decode(rawBuffer.bindMemory(to: UInt8.self), into: &output)
        }
        XCTAssertEqual(Array(output.prefix(secondCount)), [0x1F600, 0x41])
    }

    func testTerminalTextDecoderAutoDetectsUTF16BOM() {
        let decoder = TerminalTextDecoder(encoding: .utf16)
        var output = [UInt32](repeating: 0, count: 4)
        let data = Data([0xFE, 0xFF, 0x30, 0x42, 0x00, 0x41]) // あA in UTF-16BE

        let count = data.withUnsafeBytes { rawBuffer in
            decoder.decode(rawBuffer.bindMemory(to: UInt8.self), into: &output)
        }

        XCTAssertEqual(Array(output.prefix(count)), [0x3042, 0x41])
    }

    func testTerminalTextDecoderAutoDetectsLittleEndianBOM() {
        let decoder = TerminalTextDecoder(encoding: .utf16)
        var output = [UInt32](repeating: 0, count: 4)
        let data = Data([0xFF, 0xFE, 0x42, 0x30, 0x41, 0x00]) // あA in UTF-16LE

        let count = data.withUnsafeBytes { rawBuffer in
            decoder.decode(rawBuffer.bindMemory(to: UInt8.self), into: &output)
        }

        XCTAssertEqual(Array(output.prefix(count)), [0x3042, 0x41])
    }

    func testTerminalTextDecoderResetClearsPendingState() {
        let decoder = TerminalTextDecoder(encoding: .utf16LittleEndian)
        var output = [UInt32](repeating: 0, count: 4)

        let partial = Data([0x3D, 0xD8])
        _ = partial.withUnsafeBytes { rawBuffer in
            decoder.decode(rawBuffer.bindMemory(to: UInt8.self), into: &output)
        }

        decoder.reset()

        let ascii = Data([0x41, 0x00])
        let count = ascii.withUnsafeBytes { rawBuffer in
            decoder.decode(rawBuffer.bindMemory(to: UInt8.self), into: &output)
        }
        XCTAssertEqual(Array(output.prefix(count)), [0x41])
    }

    func testTerminalTextDecoderHandlesSplitUTF8AcrossChunks() {
        let decoder = TerminalTextDecoder(encoding: .utf8)
        var output = [UInt32](repeating: 0, count: 4)

        let firstChunk = Data([0xE6, 0x97])
        let secondChunk = Data([0xA5, 0xF0, 0x9F, 0x98, 0x80])

        let firstCount = firstChunk.withUnsafeBytes { rawBuffer in
            decoder.decode(rawBuffer.bindMemory(to: UInt8.self), into: &output)
        }
        XCTAssertEqual(firstCount, 0)

        let secondCount = secondChunk.withUnsafeBytes { rawBuffer in
            decoder.decode(rawBuffer.bindMemory(to: UInt8.self), into: &output)
        }
        XCTAssertEqual(Array(output.prefix(secondCount)), [0x65E5, 0x1F600])
    }

    func testTerminalTextDecoderPreservesRawC1ControlsInUTF8() {
        let decoder = TerminalTextDecoder(encoding: .utf8)
        var output = [UInt32](repeating: 0, count: 4)
        let data = Data([0x9B, 0x41])

        let count = data.withUnsafeBytes { rawBuffer in
            decoder.decode(rawBuffer.bindMemory(to: UInt8.self), into: &output)
        }

        XCTAssertEqual(Array(output.prefix(count)), [0x9B, 0x41])
    }

    func testTerminalTextDecoderEmitsReplacementForDanglingLowSurrogate() {
        let decoder = TerminalTextDecoder(encoding: .utf16LittleEndian)
        var output = [UInt32](repeating: 0, count: 4)
        let data = Data([0x00, 0xDC])

        let count = data.withUnsafeBytes { rawBuffer in
            decoder.decode(rawBuffer.bindMemory(to: UInt8.self), into: &output)
        }
        XCTAssertEqual(Array(output.prefix(count)), [0xFFFD])
    }

    func testTerminalTextDecoderStartsWithoutReusableDecodeBufferAllocation() {
        let decoder = TerminalTextDecoder(encoding: .utf8)
        XCTAssertEqual(decoder.debugDecodeBufferCapacity, 0)
    }

    func testTerminalTextDecoderReusableDecodeBufferGrowsOnlyWhenNeeded() {
        let decoder = TerminalTextDecoder(encoding: .utf8)
        decoder.debugPrimeDecodeBufferCapacity(32)
        XCTAssertEqual(decoder.debugDecodeBufferCapacity, 256)

        decoder.debugPrimeDecodeBufferCapacity(2048)
        XCTAssertGreaterThanOrEqual(decoder.debugDecodeBufferCapacity, 2048)
    }

    func testTerminalTextDecoderIdleShrinkReleasesReusableDecodeBufferCompletely() {
        let decoder = TerminalTextDecoder(encoding: .utf8)
        decoder.debugPrimeDecodeBufferCapacity(4096)
        XCTAssertGreaterThanOrEqual(decoder.debugDecodeBufferCapacity, 4096)

        decoder.debugShrinkDecodeBufferIfIdle(requiredCount: 0)
        XCTAssertEqual(decoder.debugDecodeBufferCapacity, 0)
    }

    func testTerminalTextDecoderResetReleasesBOMProbeStorage() {
        let decoder = TerminalTextDecoder(encoding: .utf16)
        decoder.debugPrimeBOMProbeCapacity(32)
        XCTAssertGreaterThan(decoder.debugBOMProbeCapacity, 0)

        decoder.reset()

        XCTAssertEqual(decoder.debugBOMProbeCapacity, 0)
    }

    func testTerminalTextDecoderAutoDetectedBOMReleasesProbeStorageImmediately() {
        let decoder = TerminalTextDecoder(encoding: .utf16)

        XCTAssertEqual(decoder.decode(Data([0xFF, 0xFE, 0x41, 0x00])), "A")
        XCTAssertEqual(decoder.debugBOMProbeCapacity, 0)
    }

    func testTerminalTextDecoderPreservesRawC1ControlsInUTF8Stream() {
        let decoder = TerminalTextDecoder(encoding: .utf8)
        var output = [UInt32](repeating: 0, count: 8)
        let bytes = Data([0x9B, 0x35, 0x6E, 0x90, 0x71, 0x9C])

        let count = bytes.withUnsafeBytes { rawBuffer in
            decoder.decode(rawBuffer.bindMemory(to: UInt8.self), into: &output)
        }

        XCTAssertEqual(Array(output.prefix(count)), [0x9B, 0x35, 0x6E, 0x90, 0x71, 0x9C])
    }

    func testTerminalTextDecoderStillDecodesValidUTF8AroundRawC1Controls() {
        let decoder = TerminalTextDecoder(encoding: .utf8)
        var output = [UInt32](repeating: 0, count: 8)
        let bytes = Data([0x41, 0x9B] + Array("あ".utf8) + [0x9C, 0x42])

        let count = bytes.withUnsafeBytes { rawBuffer in
            decoder.decode(rawBuffer.bindMemory(to: UInt8.self), into: &output)
        }

        XCTAssertEqual(Array(output.prefix(count)), [0x41, 0x9B, 0x3042, 0x9C, 0x42])
    }

    func testTerminalGridResizeRowsOnlyReturnsTrimmedRows() {
        let grid = TerminalGrid(rows: 3, cols: 4)
        grid.setCell(Cell(codepoint: 0x41, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 0)
        grid.setCell(Cell(codepoint: 0x42, attributes: .default, width: 1, isWideContinuation: false), at: 1, col: 0)
        grid.setWrapped(1, true)

        let result = grid.resize(newRows: 2, newCols: 4, cursorRow: 2, cursorCol: 1)

        XCTAssertEqual(result.trimmedRows.count, 1)
        XCTAssertEqual(result.trimmedRows.first?.cells.first?.codepoint, 0x41)
        XCTAssertEqual(result.cursorRow, 1)
        XCTAssertEqual(grid.rows, 2)
        XCTAssertEqual(grid.cols, 4)
    }

    func testTerminalGridResizeRowsOnlyPreservesRemainingWrapFlagsAcrossShrinkAndGrow() {
        let grid = TerminalGrid(rows: 4, cols: 3)
        grid.setWrapped(1, true)
        grid.setWrapped(2, true)

        _ = grid.resize(newRows: 3, newCols: 3, cursorRow: 3, cursorCol: 0)
        XCTAssertTrue(grid.isWrapped(0))
        XCTAssertTrue(grid.isWrapped(1))
        XCTAssertFalse(grid.isWrapped(2))

        _ = grid.resize(newRows: 5, newCols: 3, cursorRow: 2, cursorCol: 0)
        XCTAssertTrue(grid.isWrapped(0))
        XCTAssertTrue(grid.isWrapped(1))
        XCTAssertFalse(grid.isWrapped(2))
        XCTAssertFalse(grid.isWrapped(3))
        XCTAssertFalse(grid.isWrapped(4))
    }

    func testTerminalGridScrollUpWithinCustomScrollRegion() {
        let grid = TerminalGrid(rows: 4, cols: 2)
        for row in 0..<4 {
            for col in 0..<2 {
                grid.setCell(Cell(codepoint: UInt32(65 + row), attributes: .default, width: 1, isWideContinuation: false),
                             at: row, col: col)
            }
        }
        grid.scrollTop = 1
        grid.scrollBottom = 3

        grid.scrollUp()

        XCTAssertEqual(grid.cell(at: 0, col: 0).codepoint, 65)
        XCTAssertEqual(grid.cell(at: 1, col: 0).codepoint, 67)
        XCTAssertEqual(grid.cell(at: 2, col: 0).codepoint, 68)
        XCTAssertEqual(grid.cell(at: 3, col: 0).codepoint, 0x20)
    }

    func testTerminalGridScrollDownWithinCustomScrollRegion() {
        let grid = TerminalGrid(rows: 4, cols: 2)
        for row in 0..<4 {
            for col in 0..<2 {
                grid.setCell(Cell(codepoint: UInt32(65 + row), attributes: .default, width: 1, isWideContinuation: false),
                             at: row, col: col)
            }
        }
        grid.scrollTop = 0
        grid.scrollBottom = 2

        grid.scrollDown()

        XCTAssertEqual(grid.cell(at: 0, col: 0).codepoint, 0x20)
        XCTAssertEqual(grid.cell(at: 1, col: 0).codepoint, 65)
        XCTAssertEqual(grid.cell(at: 2, col: 0).codepoint, 66)
        XCTAssertEqual(grid.cell(at: 3, col: 0).codepoint, 68)
    }

    func testTerminalGridClearOperationsResetCellsAndWrapFlags() {
        let grid = TerminalGrid(rows: 2, cols: 3)
        grid.setCell(Cell(codepoint: 0x41, attributes: .default, width: 1, isWideContinuation: false), at: 1, col: 1)
        grid.setWrapped(1, true)
        grid.clearCells(row: 1, fromCol: 1, toCol: 1)
        XCTAssertEqual(grid.cell(at: 1, col: 1).codepoint, 0x20)
        XCTAssertTrue(grid.isWrapped(1))

        grid.clearRow(1)
        XCTAssertFalse(grid.isWrapped(1))

        grid.setCell(Cell(codepoint: 0x42, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 0)
        grid.clearAll()
        XCTAssertEqual(grid.cell(at: 0, col: 0).codepoint, 0x20)
        XCTAssertFalse(grid.isWrapped(0))
    }

    func testTerminalGridRowEncodingHintTracksCompactDefaultRowsAndRecomputesAfterMutation() {
        let grid = TerminalGrid(rows: 2, cols: 6)
        let digits = Array("123".utf8)

        digits.withUnsafeBufferPointer { bytes in
            grid.writeSingleWidthASCIIBytes(
                bytes.baseAddress!,
                count: bytes.count,
                attributes: .default,
                atRow: 0,
                startCol: 0
            )
        }

        switch grid.rowEncodingHint(0).kind {
        case .compactDefault(let serializedCount):
            XCTAssertEqual(serializedCount, 3)
        default:
            XCTFail("expected compact default hint")
        }

        grid.setCell(
            Cell(codepoint: 0x41, attributes: CellAttributes(
                foreground: .indexed(2),
                background: .default,
                bold: false,
                italic: false,
                underline: false,
                strikethrough: false,
                inverse: false,
                hidden: false,
                dim: false,
                blink: false
            ), width: 1, isWideContinuation: false),
            at: 0,
            col: 5
        )

        switch grid.rowEncodingHint(0).kind {
        case .unknown:
            break
        default:
            XCTFail("expected unknown hint after non-default mutation")
        }

        grid.clearRow(0)
        switch grid.rowEncodingHint(0).kind {
        case .compactDefault(let serializedCount):
            XCTAssertEqual(serializedCount, 0)
        default:
            XCTFail("expected blank compact default hint")
        }
    }

    func testTerminalGridRowEncodingHintIsInvalidatedByResizeAndRecomputedFromContent() {
        let grid = TerminalGrid(rows: 2, cols: 4)
        let letters = Array("ABCD".utf8)
        letters.withUnsafeBufferPointer { bytes in
            grid.writeSingleWidthASCIIBytes(
                bytes.baseAddress!,
                count: bytes.count,
                attributes: .default,
                atRow: 0,
                startCol: 0
            )
        }

        _ = grid.resize(newRows: 3, newCols: 2, cursorRow: 0, cursorCol: 0)

        switch grid.rowEncodingHint(0).kind {
        case .compactDefault(let serializedCount):
            XCTAssertEqual(serializedCount, 2)
        default:
            XCTFail("expected compact default hint after resize recomputation")
        }
        switch grid.rowEncodingHint(1).kind {
        case .compactDefault(let serializedCount):
            XCTAssertEqual(serializedCount, 2)
        default:
            XCTFail("expected compact default hint for wrapped continuation row")
        }
    }

    func testTerminalGridScrollbackCellsOnlyCopySerializedPrefixForCompactDefaultRows() {
        let grid = TerminalGrid(rows: 1, cols: 6)
        let digits = Array("123".utf8)
        digits.withUnsafeBufferPointer { bytes in
            grid.writeSingleWidthASCIIBytes(
                bytes.baseAddress!,
                count: bytes.count,
                attributes: .default,
                atRow: 0,
                startCol: 0
            )
        }

        let hint = grid.rowEncodingHint(0)
        let scrollbackCells = grid.scrollbackCells(0, encodingHint: hint)

        XCTAssertEqual(scrollbackCells.map(\.codepoint), digits.map(UInt32.init))
        switch hint.kind {
        case .compactDefault(let serializedCount):
            XCTAssertEqual(serializedCount, 3)
        default:
            XCTFail("expected compact default hint")
        }
    }

    func testTerminalGridSparseDefaultASCIIRowBehavesLikeBlankTailUntilMaterialized() {
        let grid = TerminalGrid(rows: 1, cols: 8)
        let digits = Array("123".utf8)
        digits.withUnsafeBufferPointer { bytes in
            grid.writeSingleWidthDefaultASCIIBytesWithoutSpaces(
                bytes.baseAddress!,
                count: bytes.count,
                atRow: 0,
                startCol: 0
            )
        }

        XCTAssertEqual(grid.rowCells(0).map(\.codepoint), digits.map(UInt32.init))
        XCTAssertEqual(grid.cell(at: 0, col: 0).codepoint, UInt32(Character("1").asciiValue!))
        XCTAssertEqual(grid.cell(at: 0, col: 3).codepoint, Cell.empty.codepoint)
        XCTAssertEqual(grid.cell(at: 0, col: 7).codepoint, Cell.empty.codepoint)

        grid.setCell(
            Cell(codepoint: UInt32(Character("Z").asciiValue!), attributes: .default, width: 1, isWideContinuation: false),
            at: 0,
            col: 5
        )

        XCTAssertEqual(grid.cell(at: 0, col: 0).codepoint, UInt32(Character("1").asciiValue!))
        XCTAssertEqual(grid.cell(at: 0, col: 3).codepoint, Cell.empty.codepoint)
        XCTAssertEqual(grid.cell(at: 0, col: 5).codepoint, UInt32(Character("Z").asciiValue!))
        XCTAssertEqual(grid.rowCells(0).count, 8)
    }

    func testTerminalGridSparseDefaultASCIIRowCanExtendWithoutMaterializingBlankTail() {
        let grid = TerminalGrid(rows: 1, cols: 8)
        Array("123".utf8).withUnsafeBufferPointer { bytes in
            grid.writeSingleWidthDefaultASCIIBytesWithoutSpaces(
                bytes.baseAddress!,
                count: bytes.count,
                atRow: 0,
                startCol: 0
            )
        }
        Array("45".utf8).withUnsafeBufferPointer { bytes in
            grid.writeSingleWidthDefaultASCIIBytesWithoutSpaces(
                bytes.baseAddress!,
                count: bytes.count,
                atRow: 0,
                startCol: 3
            )
        }

        switch grid.rowEncodingHint(0).kind {
        case .compactDefault(let serializedCount):
            XCTAssertEqual(serializedCount, 5)
        default:
            XCTFail("expected compact default hint after sparse append")
        }
        XCTAssertEqual(grid.rowCells(0).map(\.codepoint), Array("12345".utf8).map(UInt32.init))
        XCTAssertEqual(grid.cell(at: 0, col: 6).codepoint, Cell.empty.codepoint)
    }

    func testTerminalGridSparseDefaultASCIIRowPreservesSpacesInsideSerializedPrefix() {
        let grid = TerminalGrid(rows: 1, cols: 8)
        Array("1 3".utf8).withUnsafeBufferPointer { bytes in
            grid.writeSingleWidthDefaultASCIIBytes(
                bytes.baseAddress!,
                count: bytes.count,
                atRow: 0,
                startCol: 0
            )
        }

        switch grid.rowEncodingHint(0).kind {
        case .compactDefault(let serializedCount):
            XCTAssertEqual(serializedCount, 3)
        default:
            XCTFail("expected compact default hint for sparse ASCII row with spaces")
        }

        XCTAssertEqual(grid.cell(at: 0, col: 0).codepoint, UInt32(Character("1").asciiValue!))
        XCTAssertEqual(grid.cell(at: 0, col: 1).codepoint, Cell.empty.codepoint)
        XCTAssertEqual(grid.cell(at: 0, col: 2).codepoint, UInt32(Character("3").asciiValue!))
        XCTAssertEqual(grid.cell(at: 0, col: 5).codepoint, Cell.empty.codepoint)
    }

    func testTerminalGridSparseDefaultUnicodeRowBehavesLikeBlankTailUntilMaterialized() {
        let grid = TerminalGrid(rows: 1, cols: 8)
        let codepoints: [UInt32] = [0x03B1, 0x03B2, 0x03B3]
        codepoints.withUnsafeBufferPointer { buffer in
            grid.writeSingleWidthDefaultCells(
                buffer.baseAddress!,
                count: buffer.count,
                atRow: 0,
                startCol: 0
            )
        }

        XCTAssertEqual(grid.rowCells(0).map(\.codepoint), codepoints)
        XCTAssertEqual(grid.cell(at: 0, col: 0).codepoint, 0x03B1)
        XCTAssertEqual(grid.cell(at: 0, col: 3).codepoint, Cell.empty.codepoint)
        XCTAssertEqual(grid.cell(at: 0, col: 7).codepoint, Cell.empty.codepoint)

        grid.setCell(
            Cell(codepoint: 0x03B6, attributes: .default, width: 1, isWideContinuation: false),
            at: 0,
            col: 5
        )

        XCTAssertEqual(grid.cell(at: 0, col: 0).codepoint, 0x03B1)
        XCTAssertEqual(grid.cell(at: 0, col: 3).codepoint, Cell.empty.codepoint)
        XCTAssertEqual(grid.cell(at: 0, col: 5).codepoint, 0x03B6)
        XCTAssertEqual(grid.rowCells(0).count, 8)
    }

    func testTerminalGridSparseDefaultUnicodeRowCanExtendWithoutMaterializingBlankTail() {
        let grid = TerminalGrid(rows: 1, cols: 8)
        [UInt32(0x03B1), 0x03B2, 0x03B3].withUnsafeBufferPointer { buffer in
            grid.writeSingleWidthDefaultCells(
                buffer.baseAddress!,
                count: buffer.count,
                atRow: 0,
                startCol: 0
            )
        }
        [UInt32(0x03B4), 0x03B5].withUnsafeBufferPointer { buffer in
            grid.writeSingleWidthDefaultCells(
                buffer.baseAddress!,
                count: buffer.count,
                atRow: 0,
                startCol: 3
            )
        }

        switch grid.rowEncodingHint(0).kind {
        case .compactDefault(let serializedCount):
            XCTAssertEqual(serializedCount, 5)
        default:
            XCTFail("expected compact default hint after sparse Unicode append")
        }
        XCTAssertEqual(grid.rowCells(0).map(\.codepoint), [UInt32(0x03B1), 0x03B2, 0x03B3, 0x03B4, 0x03B5])
        XCTAssertEqual(grid.cell(at: 0, col: 6).codepoint, Cell.empty.codepoint)
    }

    func testTerminalGridRowOnlyResizeMaterializesSparseRowsBackToViewportWidth() {
        let grid = TerminalGrid(rows: 1, cols: 8)
        [UInt32(0x03B1), 0x03B2, 0x03B3].withUnsafeBufferPointer { buffer in
            grid.writeSingleWidthDefaultCells(
                buffer.baseAddress!,
                count: buffer.count,
                atRow: 0,
                startCol: 0
            )
        }

        XCTAssertEqual(grid.rowCells(0).count, 3)

        _ = grid.resize(newRows: 2, newCols: 8, cursorRow: 0, cursorCol: 2)

        XCTAssertEqual(grid.rowCells(0).count, 8)
        XCTAssertEqual(grid.rowCells(1).count, 8)
        XCTAssertEqual(grid.cell(at: 0, col: 0).codepoint, 0x03B1)
        XCTAssertEqual(grid.cell(at: 0, col: 1).codepoint, 0x03B2)
        XCTAssertEqual(grid.cell(at: 0, col: 2).codepoint, 0x03B3)
        XCTAssertEqual(grid.cell(at: 0, col: 3).codepoint, Cell.empty.codepoint)
        XCTAssertTrue(grid.debugValidateInternalInvariants().isEmpty)
    }

    func testTerminalGridRowOnlyResizeRepairsUnreadableMetadataRowsIntoBlankRows() {
        let grid = TerminalGrid(rows: 3, cols: 4)
        grid.setCell(Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 0)
        grid.setCell(Cell(codepoint: 66, attributes: .default, width: 1, isWideContinuation: false), at: 1, col: 0)
        grid.debugCorruptReadableStateForTesting(
            physicalSparseCompactDefaultPrefixCounts: [0, 0],
            rowEncodingHintStatesCount: 2
        )

        let result = grid.resize(newRows: 4, newCols: 4, cursorRow: 2, cursorCol: 0)

        XCTAssertEqual(result.cursorRow, 2)
        XCTAssertEqual(grid.rowCells(0).count, 4)
        XCTAssertEqual(grid.rowCells(1).count, 4)
        XCTAssertEqual(grid.rowCells(2).count, 4)
        XCTAssertEqual(grid.cell(at: 0, col: 0).codepoint, 65)
        XCTAssertEqual(grid.cell(at: 1, col: 0).codepoint, 66)
        XCTAssertEqual(grid.cell(at: 2, col: 0).codepoint, Cell.empty.codepoint)
        XCTAssertTrue(grid.debugValidateInternalInvariants().isEmpty)
    }

    func testTerminalGridOutOfBoundsAccessIsSafe() {
        let grid = TerminalGrid(rows: 2, cols: 2)
        XCTAssertEqual(grid.cell(at: -1, col: 0).codepoint, 0x20)
        XCTAssertEqual(grid.cell(at: 99, col: 99).codepoint, 0x20)
        grid.setCell(Cell(codepoint: 0x41, attributes: .default, width: 1, isWideContinuation: false), at: 99, col: 99)
        XCTAssertEqual(grid.cell(at: 0, col: 0).codepoint, 0x20)
    }

    func testTerminalGridInsertDeleteClampCountsToRowWidth() {
        let grid = TerminalGrid(rows: 1, cols: 4)
        for (col, codepoint) in [UInt32(65), 66, 67, 68].enumerated() {
            grid.setCell(Cell(codepoint: codepoint, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: col)
        }

        grid.insertBlanks(row: 0, col: 2, count: 99)
        XCTAssertEqual(grid.rowCells(0).map(\.codepoint), [65, 66, 0x20, 0x20])

        grid.deleteCells(row: 0, col: 1, count: 99)
        XCTAssertEqual(grid.rowCells(0).map(\.codepoint), [65, 0x20, 0x20, 0x20])
    }

    func testTerminalGridScrollByRegionHeightClearsRegion() {
        let grid = TerminalGrid(rows: 3, cols: 2)
        for row in 0..<3 {
            for col in 0..<2 {
                grid.setCell(Cell(codepoint: UInt32(65 + row), attributes: .default, width: 1, isWideContinuation: false), at: row, col: col)
            }
        }
        grid.scrollTop = 0
        grid.scrollBottom = 1

        grid.scrollUp(count: 2)

        XCTAssertEqual(grid.cell(at: 0, col: 0).codepoint, 0x20)
        XCTAssertEqual(grid.cell(at: 1, col: 0).codepoint, 0x20)
        XCTAssertEqual(grid.cell(at: 2, col: 0).codepoint, 67)
    }

    func testTerminalGridFullScreenScrollUpByMultipleRowsPreservesContentAndWrapFlags() {
        let grid = TerminalGrid(rows: 5, cols: 2)
        for row in 0..<5 {
            for col in 0..<2 {
                grid.setCell(
                    Cell(codepoint: UInt32(65 + row), attributes: .default, width: 1, isWideContinuation: false),
                    at: row,
                    col: col
                )
            }
        }
        grid.setWrapped(1, true)
        grid.setWrapped(3, true)

        grid.scrollUp(count: 2)

        XCTAssertEqual(grid.rowCells(0).map(\.codepoint), [67, 67])
        XCTAssertEqual(grid.rowCells(1).map(\.codepoint), [68, 68])
        XCTAssertEqual(grid.rowCells(2).map(\.codepoint), [69, 69])
        XCTAssertEqual(grid.rowCells(3).map(\.codepoint), [0x20, 0x20])
        XCTAssertEqual(grid.rowCells(4).map(\.codepoint), [0x20, 0x20])
        XCTAssertFalse(grid.isWrapped(0))
        XCTAssertTrue(grid.isWrapped(1))
        XCTAssertFalse(grid.isWrapped(2))
        XCTAssertFalse(grid.isWrapped(3))
        XCTAssertFalse(grid.isWrapped(4))
    }

    func testTerminalGridFullScreenScrollDownByMultipleRowsPreservesContentAndWrapFlags() {
        let grid = TerminalGrid(rows: 5, cols: 2)
        for row in 0..<5 {
            for col in 0..<2 {
                grid.setCell(
                    Cell(codepoint: UInt32(65 + row), attributes: .default, width: 1, isWideContinuation: false),
                    at: row,
                    col: col
                )
            }
        }
        grid.setWrapped(2, true)
        grid.setWrapped(4, true)

        grid.scrollDown(count: 2)

        XCTAssertEqual(grid.rowCells(0).map(\.codepoint), [0x20, 0x20])
        XCTAssertEqual(grid.rowCells(1).map(\.codepoint), [0x20, 0x20])
        XCTAssertEqual(grid.rowCells(2).map(\.codepoint), [65, 65])
        XCTAssertEqual(grid.rowCells(3).map(\.codepoint), [66, 66])
        XCTAssertEqual(grid.rowCells(4).map(\.codepoint), [67, 67])
        XCTAssertFalse(grid.isWrapped(0))
        XCTAssertFalse(grid.isWrapped(1))
        XCTAssertFalse(grid.isWrapped(2))
        XCTAssertFalse(grid.isWrapped(3))
        XCTAssertTrue(grid.isWrapped(4))
    }

    func testTerminalGridResizeRewrapsLogicalLinesAndPreservesCursor() {
        let grid = TerminalGrid(rows: 2, cols: 4)
        let characters: [UInt32] = [0x41, 0x42, 0x43, 0x44, 0x45, 0x46]
        for (index, codepoint) in characters.enumerated() {
            grid.setCell(Cell(codepoint: codepoint, attributes: .default, width: 1, isWideContinuation: false),
                         at: index / 4, col: index % 4)
        }
        grid.setWrapped(1, true)

        let result = grid.resize(newRows: 3, newCols: 3, cursorRow: 1, cursorCol: 1)

        XCTAssertEqual(result.cursorRow, 1)
        XCTAssertEqual(result.cursorCol, 2)
        XCTAssertEqual(grid.cell(at: 0, col: 0).codepoint, 0x41)
        XCTAssertEqual(grid.cell(at: 0, col: 2).codepoint, 0x43)
        XCTAssertEqual(grid.cell(at: 1, col: 0).codepoint, 0x44)
        XCTAssertEqual(grid.cell(at: 1, col: 2).codepoint, 0x46)
        XCTAssertTrue(grid.isWrapped(1))
        XCTAssertFalse(grid.isWrapped(0))
    }

    func testTerminalGridWrapFlagsWorkAcrossBitsetWordBoundary() {
        let grid = TerminalGrid(rows: 130, cols: 2)
        grid.setWrapped(0, true)
        grid.setWrapped(63, true)
        grid.setWrapped(64, true)
        grid.setWrapped(129, true)

        XCTAssertTrue(grid.isWrapped(0))
        XCTAssertTrue(grid.isWrapped(63))
        XCTAssertTrue(grid.isWrapped(64))
        XCTAssertTrue(grid.isWrapped(129))
        XCTAssertFalse(grid.isWrapped(1))
        XCTAssertFalse(grid.isWrapped(65))
    }

    func testTerminalGridScrollOperationsPreserveWrapFlagsAcrossBitsetWordBoundary() {
        let grid = TerminalGrid(rows: 66, cols: 1)
        for row in 0..<66 {
            grid.setCell(
                Cell(codepoint: UInt32(65 + (row % 26)), attributes: .default, width: 1, isWideContinuation: false),
                at: row,
                col: 0
            )
        }
        grid.setWrapped(63, true)
        grid.setWrapped(64, true)

        grid.scrollUp()
        XCTAssertTrue(grid.isWrapped(62))
        XCTAssertTrue(grid.isWrapped(63))

        grid.scrollDown()
        XCTAssertFalse(grid.isWrapped(0))
        XCTAssertTrue(grid.isWrapped(63))
        XCTAssertTrue(grid.isWrapped(64))
    }

    func testTerminalSelectionExtractsNormalSelectionAcrossWrappedLinesWithoutExtraNewline() {
        let grid = TerminalGrid(rows: 2, cols: 4)
        let row0: [UInt32] = [0x61, 0x62, 0x63, 0x20]
        let row1: [UInt32] = [0x64, 0x65, 0x20, 0x20]
        for (col, codepoint) in row0.enumerated() {
            grid.setCell(Cell(codepoint: codepoint, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: col)
        }
        for (col, codepoint) in row1.enumerated() {
            grid.setCell(Cell(codepoint: codepoint, attributes: .default, width: 1, isWideContinuation: false), at: 1, col: col)
        }
        grid.setWrapped(1, true)

        let selection = TerminalSelection(anchor: .init(row: 0, col: 0), active: .init(row: 1, col: 1), mode: .normal)
        XCTAssertEqual(selection.extractText(from: grid), "abcde")
    }

    func testTerminalSelectionExtractsRectangularSelectionWithRowBreaks() {
        let grid = TerminalGrid(rows: 2, cols: 4)
        for row in 0..<2 {
            for col in 0..<4 {
                let codepoint = UInt32(65 + row * 4 + col)
                grid.setCell(Cell(codepoint: codepoint, attributes: .default, width: 1, isWideContinuation: false), at: row, col: col)
            }
        }

        let selection = TerminalSelection(anchor: .init(row: 0, col: 1), active: .init(row: 1, col: 2), mode: .rectangular)
        XCTAssertEqual(selection.extractText(from: grid), "BC\nFG")
    }

    func testTerminalSelectionSkipsWideContinuationCellWhenExtracting() {
        let grid = TerminalGrid(rows: 1, cols: 2)
        grid.setCell(Cell(codepoint: 0x3042, attributes: .default, width: 2, isWideContinuation: false), at: 0, col: 0)
        grid.setCell(Cell(codepoint: 0x20, attributes: .default, width: 0, isWideContinuation: true), at: 0, col: 1)

        let selection = TerminalSelection(anchor: .init(row: 0, col: 0), active: .init(row: 0, col: 1), mode: .normal)
        XCTAssertEqual(selection.extractText(from: grid), "あ")
    }

    func testTerminalSelectionWordSelectionStopsAtConfiguredDelimiters() {
        let grid = TerminalGrid(rows: 1, cols: 12)
        let text = Array("/tmp/foo.txt".unicodeScalars.map(\.value))
        for (col, codepoint) in text.enumerated() {
            grid.setCell(Cell(codepoint: codepoint, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: col)
        }

        let selection = TerminalSelection.wordSelection(at: .init(row: 0, col: 5), in: grid)
        XCTAssertEqual(selection.extractText(from: grid), "foo")
    }

    func testTerminalSelectionWordDelimiterClassification() {
        XCTAssertTrue(TerminalSelection.isWordDelimiter(UInt32(Character("/").unicodeScalars.first!.value)))
        XCTAssertTrue(TerminalSelection.isWordDelimiter(UInt32(Character(" ").unicodeScalars.first!.value)))
        XCTAssertFalse(TerminalSelection.isWordDelimiter(UInt32(Character("A").unicodeScalars.first!.value)))
    }

    func testTerminalSelectionLineSelectionCoversEntireRow() {
        let selection = TerminalSelection.lineSelection(row: 3, cols: 5)
        XCTAssertEqual(selection.start, .init(row: 3, col: 0))
        XCTAssertEqual(selection.end, .init(row: 3, col: 4))
        XCTAssertFalse(selection.isEmpty)
    }

    func testTerminalSelectionRectangularContainsOnlyColumnsWithinBounds() {
        let selection = TerminalSelection(
            anchor: .init(row: 2, col: 4),
            active: .init(row: 0, col: 1),
            mode: .rectangular
        )

        XCTAssertEqual(selection.start, .init(row: 0, col: 1))
        XCTAssertEqual(selection.end, .init(row: 2, col: 4))
        XCTAssertTrue(selection.contains(row: 1, col: 3))
        XCTAssertFalse(selection.contains(row: 1, col: 0))
        XCTAssertFalse(selection.contains(row: 3, col: 3))
    }

    func testTerminalSelectionRectangularExtractionTrimsTrailingSpacesPerRow() {
        let grid = TerminalGrid(rows: 2, cols: 4)
        grid.setCell(Cell(codepoint: 0x41, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 0)
        grid.setCell(Cell(codepoint: 0x42, attributes: .default, width: 1, isWideContinuation: false), at: 1, col: 0)

        let selection = TerminalSelection(
            anchor: .init(row: 0, col: 0),
            active: .init(row: 1, col: 3),
            mode: .rectangular
        )

        XCTAssertEqual(selection.extractText(from: grid), "A\nB   ")
    }

    func testTerminalSelectionWordSelectionAtDelimiterReturnsDelimiterCellOnly() {
        let grid = TerminalGrid(rows: 1, cols: 5)
        for (col, scalar) in Array("a/b c".unicodeScalars.map(\.value)).enumerated() {
            guard col < grid.cols else { break }
            grid.setCell(Cell(codepoint: scalar, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: col)
        }

        let selection = TerminalSelection.wordSelection(at: .init(row: 0, col: 1), in: grid)
        XCTAssertEqual(selection.start, .init(row: 0, col: 0))
        XCTAssertEqual(selection.end, .init(row: 0, col: 2))
        XCTAssertEqual(selection.extractText(from: grid), "a/b")
    }

    func testTerminalSelectionNormalizesReversedAnchorAndContainsExpectedCells() {
        let selection = TerminalSelection(
            anchor: .init(row: 2, col: 4),
            active: .init(row: 1, col: 1),
            mode: .normal
        )

        XCTAssertEqual(selection.start, .init(row: 1, col: 1))
        XCTAssertEqual(selection.end, .init(row: 2, col: 4))
        XCTAssertTrue(selection.contains(row: 1, col: 3))
        XCTAssertTrue(selection.contains(row: 2, col: 2))
        XCTAssertFalse(selection.contains(row: 0, col: 0))
    }

    func testTerminalSelectionEmptyExtractsNothing() {
        let grid = TerminalGrid(rows: 1, cols: 1)
        let selection = TerminalSelection(anchor: .init(row: 0, col: 0), active: .init(row: 0, col: 0), mode: .normal)
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.extractText(from: grid), "")
    }

    func testScrollbackBufferRoundTripsCellsAndWrapFlags() throws {
        let buffer = ScrollbackBuffer(initialCapacity: 1024, maxCapacity: 1024)
        let cell = Cell(codepoint: 0x3042, attributes: .init(foreground: .rgb(1, 2, 3), background: .indexed(4), bold: true, italic: false, underline: true, strikethrough: false, inverse: false, hidden: false, dim: true, blink: false), width: 2, isWideContinuation: false)
        let continuation = Cell(codepoint: 0x20, attributes: .default, width: 0, isWideContinuation: true)

        buffer.appendRow([cell, continuation][0...1], isWrapped: true)

        let row = try XCTUnwrap(buffer.getRow(at: 0))
        XCTAssertEqual(row.count, 2)
        XCTAssertEqual(row[0].codepoint, 0x3042)
        XCTAssertEqual(row[0].attributes.foreground, .rgb(1, 2, 3))
        XCTAssertEqual(row[0].attributes.background, .indexed(4))
        XCTAssertTrue(buffer.isRowWrapped(at: 0))
    }

    func testScrollbackBufferCompactDefaultRowsFitMoreHistoryWithinSameCapacity() throws {
        let buffer = ScrollbackBuffer(initialCapacity: 80, maxCapacity: 80)
        let row = ArraySlice("abcd".unicodeScalars.map {
            Cell(codepoint: $0.value, attributes: .default, width: 1, isWideContinuation: false)
        })

        for _ in 0..<4 {
            buffer.appendRow(row, isWrapped: false)
        }

        XCTAssertEqual(buffer.rowCount, 4)
        let firstRow = try XCTUnwrap(buffer.getRow(at: 0))
        XCTAssertEqual(
            String(firstRow.compactMap { Unicode.Scalar($0.codepoint).map(Character.init) }),
            "abcd"
        )
    }

    func testScrollbackBufferCompactDefaultRowsTrimTrailingDefaultBlanksAndRoundTripOriginalWidth() throws {
        let buffer = ScrollbackBuffer(initialCapacity: 128, maxCapacity: 128)
        let row: ArraySlice<Cell> = [
            Cell(codepoint: 0x61, attributes: .default, width: 1, isWideContinuation: false),
            Cell(codepoint: 0x62, attributes: .default, width: 1, isWideContinuation: false),
            .empty,
            .empty
        ][0...3]

        buffer.appendRow(row, isWrapped: false)

        let restored = try XCTUnwrap(buffer.getRow(at: 0))
        XCTAssertEqual(restored.count, 4)
        XCTAssertEqual(restored[0].codepoint, 0x61)
        XCTAssertEqual(restored[1].codepoint, 0x62)
        XCTAssertEqual(restored[2].codepoint, Cell.empty.codepoint)
        XCTAssertEqual(restored[2].attributes, .default)
        XCTAssertEqual(restored[2].width, Cell.empty.width)
        XCTAssertFalse(restored[2].isWideContinuation)
        XCTAssertEqual(restored[3].codepoint, Cell.empty.codepoint)
        XCTAssertEqual(restored[3].attributes, .default)
        XCTAssertEqual(restored[3].width, Cell.empty.width)
        XCTAssertFalse(restored[3].isWideContinuation)
    }

    func testScrollbackBufferPreservesStyledRowsWithLegacyEncoding() throws {
        let buffer = ScrollbackBuffer(initialCapacity: 256, maxCapacity: 256)
        let styledRow: ArraySlice<Cell> = [
            Cell(
                codepoint: 0x41,
                attributes: CellAttributes(
                    foreground: .indexed(196),
                    background: .rgb(1, 2, 3),
                    bold: true,
                    italic: true,
                    underline: true,
                    strikethrough: false,
                    inverse: false,
                    hidden: false,
                    dim: false,
                    blink: false
                ),
                width: 1,
                isWideContinuation: false
            ),
            Cell(
                codepoint: 0x4E2D,
                attributes: .default,
                width: 2,
                isWideContinuation: false
            )
        ][0...1]

        buffer.appendRow(styledRow, isWrapped: true)

        let row = try XCTUnwrap(buffer.getRow(at: 0))
        XCTAssertEqual(row.count, 2)
        XCTAssertEqual(row[0].codepoint, 0x41)
        XCTAssertEqual(row[0].attributes.foreground, .indexed(196))
        XCTAssertEqual(row[0].attributes.background, .rgb(1, 2, 3))
        XCTAssertTrue(row[0].attributes.bold)
        XCTAssertTrue(row[0].attributes.italic)
        XCTAssertTrue(row[0].attributes.underline)
        XCTAssertEqual(row[1].codepoint, 0x4E2D)
        XCTAssertEqual(row[1].width, 2)
        XCTAssertTrue(buffer.isRowWrapped(at: 0))
    }

    func testScrollbackBufferPreservesUnderlineColorAndStyle() throws {
        let buffer = ScrollbackBuffer(initialCapacity: 256, maxCapacity: 256)
        let styledRow: ArraySlice<Cell> = [
            Cell(
                codepoint: 0x41,
                attributes: CellAttributes(
                    foreground: .indexed(196),
                    background: .rgb(1, 2, 3),
                    bold: true,
                    italic: false,
                    underline: true,
                    strikethrough: false,
                    inverse: false,
                    hidden: false,
                    dim: false,
                    blink: false,
                    underlineStyle: .curly,
                    underlineColor: .indexed(44)
                ),
                width: 1,
                isWideContinuation: false
            )
        ][0...0]

        buffer.appendRow(styledRow, isWrapped: false)

        let row = try XCTUnwrap(buffer.getRow(at: 0))
        XCTAssertEqual(row[0].attributes.underlineStyle, .curly)
        XCTAssertEqual(row[0].attributes.underlineColor, .indexed(44))
    }

    func testScrollbackBufferCompactUniformAttributeRowsFitMoreHistoryWithinSameCapacity() throws {
        let buffer = ScrollbackBuffer(initialCapacity: 140, maxCapacity: 140)
        let sharedAttributes = CellAttributes(
            foreground: .indexed(196),
            background: .default,
            bold: true,
            italic: false,
            underline: false,
            strikethrough: false,
            inverse: false,
            hidden: false,
            dim: false,
            blink: false
        )
        let row = ArraySlice("abcd".unicodeScalars.map {
            Cell(codepoint: $0.value, attributes: sharedAttributes, width: 1, isWideContinuation: false)
        })

        for _ in 0..<4 {
            buffer.appendRow(row, isWrapped: false)
        }

        XCTAssertEqual(buffer.rowCount, 4)
        let firstRow = try XCTUnwrap(buffer.getRow(at: 0))
        XCTAssertEqual(firstRow.count, 4)
        XCTAssertEqual(firstRow[0].attributes.foreground, .indexed(196))
        XCTAssertTrue(firstRow[0].attributes.bold)
    }

    func testScrollbackBufferCompactUniformRowsTrimTrailingBlankCellsAndRestoreSharedAttributes() throws {
        let buffer = ScrollbackBuffer(initialCapacity: 128, maxCapacity: 128)
        let sharedAttributes = CellAttributes(
            foreground: .indexed(34),
            background: .rgb(1, 2, 3),
            bold: false,
            italic: true,
            underline: false,
            strikethrough: false,
            inverse: false,
            hidden: false,
            dim: false,
            blink: false
        )
        let blank = Cell(codepoint: 0x20, attributes: sharedAttributes, width: 1, isWideContinuation: false)
        let row: ArraySlice<Cell> = [
            Cell(codepoint: 0x61, attributes: sharedAttributes, width: 1, isWideContinuation: false),
            blank,
            blank
        ][0...2]

        buffer.appendRow(row, isWrapped: false)

        let restored = try XCTUnwrap(buffer.getRow(at: 0))
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored[0].codepoint, 0x61)
        XCTAssertEqual(restored[1].codepoint, blank.codepoint)
        XCTAssertEqual(restored[1].attributes, sharedAttributes)
        XCTAssertEqual(restored[1].width, blank.width)
        XCTAssertFalse(restored[1].isWideContinuation)
        XCTAssertEqual(restored[2].codepoint, blank.codepoint)
        XCTAssertEqual(restored[2].attributes, sharedAttributes)
        XCTAssertEqual(restored[2].width, blank.width)
        XCTAssertFalse(restored[2].isWideContinuation)
    }

    func testScrollbackBufferCanDecodeRowIntoReusableDestinationBuffer() throws {
        let buffer = ScrollbackBuffer(initialCapacity: 128, maxCapacity: 128)
        let row: ArraySlice<Cell> = [
            Cell(codepoint: 0x41, attributes: .default, width: 1, isWideContinuation: false),
            Cell(codepoint: 0x42, attributes: .default, width: 1, isWideContinuation: false)
        ][0...1]

        buffer.appendRow(row, isWrapped: false)

        var destination = [Cell]()
        destination.reserveCapacity(8)
        destination.append(Cell.empty)

        XCTAssertTrue(buffer.getRow(at: 0, into: &destination))
        XCTAssertEqual(destination.map(\.codepoint), [0x41, 0x42])
        XCTAssertGreaterThanOrEqual(destination.capacity, 8)
    }

    func testScrollbackBufferRecentRowsAreVisibleBeforeArchivedFlush() throws {
        let buffer = ScrollbackBuffer(initialCapacity: 256, maxCapacity: 256)
        let rowA: ArraySlice<Cell> = [
            Cell(codepoint: 0x41, attributes: .default, width: 1, isWideContinuation: false)
        ][0...0]
        let rowB: ArraySlice<Cell> = [
            Cell(codepoint: 0x42, attributes: .default, width: 1, isWideContinuation: false)
        ][0...0]

        buffer.appendRow(rowA, isWrapped: false)
        buffer.appendRow(rowB, isWrapped: true)

        XCTAssertEqual(buffer.rowCount, 2)
        XCTAssertEqual(try XCTUnwrap(buffer.getRow(at: 0)).map(\.codepoint), [0x41])
        XCTAssertEqual(try XCTUnwrap(buffer.getRow(at: 1)).map(\.codepoint), [0x42])
        XCTAssertFalse(buffer.isRowWrapped(at: 0))
        XCTAssertTrue(buffer.isRowWrapped(at: 1))

        buffer.flushPendingRows()

        XCTAssertEqual(buffer.rowCount, 2)
        XCTAssertEqual(try XCTUnwrap(buffer.getRow(at: 0)).map(\.codepoint), [0x41])
        XCTAssertEqual(try XCTUnwrap(buffer.getRow(at: 1)).map(\.codepoint), [0x42])
        XCTAssertFalse(buffer.isRowWrapped(at: 0))
        XCTAssertTrue(buffer.isRowWrapped(at: 1))
    }

    func testScrollbackBufferRecentCompactRowsDecodeBeforeArchivedFlush() throws {
        let buffer = ScrollbackBuffer(initialCapacity: 256, maxCapacity: 256)
        let row: ArraySlice<Cell> = [
            Cell(codepoint: 0x31, attributes: .default, width: 1, isWideContinuation: false),
            Cell(codepoint: 0x32, attributes: .default, width: 1, isWideContinuation: false),
            .empty,
            .empty
        ][0...3]

        buffer.appendRow(row, isWrapped: false)

        XCTAssertEqual(buffer.rowCount, 1)
        let restoredBeforeFlush = try XCTUnwrap(buffer.getRow(at: 0))
        XCTAssertEqual(restoredBeforeFlush.count, 4)
        XCTAssertEqual(restoredBeforeFlush[0].codepoint, 0x31)
        XCTAssertEqual(restoredBeforeFlush[1].codepoint, 0x32)
        XCTAssertEqual(restoredBeforeFlush[2].codepoint, Cell.empty.codepoint)
        XCTAssertEqual(restoredBeforeFlush[3].codepoint, Cell.empty.codepoint)

        buffer.flushPendingRows()

        let restoredAfterFlush = try XCTUnwrap(buffer.getRow(at: 0))
        XCTAssertEqual(restoredAfterFlush.map(\.codepoint), restoredBeforeFlush.map(\.codepoint))
    }

    func testScrollbackBufferTrimmedCompactRowsFitMoreHistoryWithinSameCapacity() throws {
        let buffer = ScrollbackBuffer(initialCapacity: 64, maxCapacity: 64)
        let row: ArraySlice<Cell> = [
            Cell(codepoint: 0x61, attributes: .default, width: 1, isWideContinuation: false),
            .empty,
            .empty,
            .empty
        ][0...3]

        for _ in 0..<6 {
            buffer.appendRow(row, isWrapped: false)
        }

        XCTAssertEqual(buffer.rowCount, 6)
        let restored = try XCTUnwrap(buffer.getRow(at: 0))
        XCTAssertEqual(restored.count, 4)
        XCTAssertEqual(restored[0].codepoint, 0x61)
        for index in 1...3 {
            XCTAssertEqual(restored[index].codepoint, Cell.empty.codepoint)
            XCTAssertEqual(restored[index].attributes, .default)
            XCTAssertEqual(restored[index].width, Cell.empty.width)
            XCTAssertFalse(restored[index].isWideContinuation)
        }
    }

    func testScrollbackBufferPersistentStoreCanBeDiscarded() throws {
        try withTemporaryDirectory { directory in
            let backingFile = directory.appendingPathComponent("scrollback.bin")
            var buffer: ScrollbackBuffer? = ScrollbackBuffer(
                initialCapacity: 1024,
                maxCapacity: 1024,
                persistentPath: backingFile.path
            )
            buffer?.appendRow([Cell.empty][0...0], isWrapped: false)
            XCTAssertTrue(FileManager.default.fileExists(atPath: backingFile.path))

            buffer?.discardPersistentBackingStore()
            buffer = nil

            XCTAssertFalse(FileManager.default.fileExists(atPath: backingFile.path))
        }
    }

    func testScrollbackBufferClearReleasesOversizedSerializationBuffer() throws {
        let buffer = ScrollbackBuffer(initialCapacity: 1024, maxCapacity: 1024)
        let longRow = ArraySlice((0..<400).map { index in
            Cell(
                codepoint: 0x61,
                attributes: .init(
                    foreground: .default,
                    background: .indexed(UInt8(index % 200)),
                    bold: false,
                    italic: false,
                    underline: index.isMultiple(of: 2),
                    strikethrough: false,
                    inverse: false,
                    hidden: false,
                    dim: false,
                    blink: false
                ),
                width: 1,
                isWideContinuation: false
            )
        })

        buffer.appendRow(longRow, isWrapped: false)
        XCTAssertGreaterThan(buffer.serializationBufferCapacity, 0)

        buffer.clear()

        XCTAssertEqual(buffer.serializationBufferCapacity, 0)
        XCTAssertEqual(buffer.rowCount, 0)
    }

    func testScrollbackBufferIdleCompactionReleasesSerializationScratchCompletely() throws {
        let capacity = max(16 * 1024, ScrollbackBuffer.bytesPerCell * 512)
        let buffer = ScrollbackBuffer(initialCapacity: capacity, maxCapacity: capacity)
        let longRow = ArraySlice((0..<300).map { index in
            Cell(
                codepoint: 0x41,
                attributes: .init(
                    foreground: .indexed(UInt8(index % 16)),
                    background: .rgb(UInt8(index % 255), 2, 3),
                    bold: index.isMultiple(of: 3),
                    italic: false,
                    underline: false,
                    strikethrough: false,
                    inverse: false,
                    hidden: false,
                    dim: false,
                    blink: false
                ),
                width: 1,
                isWideContinuation: false
            )
        })
        let shortRow = ArraySlice("ok".unicodeScalars.map {
            Cell(codepoint: $0.value, attributes: .default, width: 1, isWideContinuation: false)
        })

        buffer.appendRow(longRow, isWrapped: false)
        let peakScratch = buffer.serializationBufferCapacity
        XCTAssertGreaterThan(peakScratch, 4 * 1024)

        buffer.appendRow(shortRow, isWrapped: false)

        _ = buffer.compactIfUnderutilized()
        XCTAssertEqual(buffer.serializationBufferCapacity, 0)
        XCTAssertEqual(buffer.rowCount, 2)
        XCTAssertEqual(try XCTUnwrap(buffer.getRow(at: 1)).map(\.codepoint), [0x6F, 0x6B])
    }

    func testScrollbackBufferAppendPathShrinksOversizedSerializationScratchForSmallRows() {
        let capacity = max(16 * 1024, ScrollbackBuffer.bytesPerCell * 512)
        let buffer = ScrollbackBuffer(initialCapacity: capacity, maxCapacity: capacity)
        let largeRow = ArraySlice((0..<300).map { index in
            Cell(
                codepoint: 0x41,
                attributes: .init(
                    foreground: .indexed(UInt8(index % 16)),
                    background: .rgb(UInt8(index % 255), 2, 3),
                    bold: index.isMultiple(of: 3),
                    italic: false,
                    underline: false,
                    strikethrough: false,
                    inverse: false,
                    hidden: false,
                    dim: false,
                    blink: false
                ),
                width: 1,
                isWideContinuation: false
            )
        })
        let shortRow = ArraySlice("ok".unicodeScalars.map {
            Cell(codepoint: $0.value, attributes: .default, width: 1, isWideContinuation: false)
        })

        buffer.appendRow(largeRow, isWrapped: false)
        let peakScratch = buffer.serializationBufferCapacity
        XCTAssertGreaterThan(peakScratch, 4 * 1024)

        buffer.appendRow(shortRow, isWrapped: false)

        XCTAssertEqual(buffer.serializationBufferCapacity, 4 * 1024)
        XCTAssertLessThan(buffer.serializationBufferCapacity, peakScratch)
        XCTAssertEqual(buffer.rowCount, 2)
        XCTAssertEqual(buffer.getRow(at: 1)?.map(\.codepoint), [0x6F, 0x6B])
    }
}

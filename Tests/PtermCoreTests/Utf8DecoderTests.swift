import XCTest
import PtermCore

final class Utf8DecoderTests: XCTestCase {
    func testDecodeASCIIAndMultibyteSequence() {
        var decoder = Utf8Decoder()
        utf8_decoder_init(&decoder, true)

        let bytes: [UInt8] = Array("Aあ😀".utf8)
        var output = [UInt32](repeating: 0, count: bytes.count)
        let count = bytes.withUnsafeBufferPointer {
            utf8_decoder_decode(&decoder, $0.baseAddress, $0.count, &output, output.count)
        }

        XCTAssertEqual(Array(output.prefix(count)), [0x41, 0x3042, 0x1F600])
    }

    func testDecodePreservesStateAcrossChunkBoundaries() {
        var decoder = Utf8Decoder()
        utf8_decoder_init(&decoder, true)

        let firstChunk: [UInt8] = [0xE3, 0x81]
        let secondChunk: [UInt8] = [0x82, 0x42]
        var output = [UInt32](repeating: 0, count: 4)

        let firstCount = firstChunk.withUnsafeBufferPointer {
            utf8_decoder_decode(&decoder, $0.baseAddress, $0.count, &output, output.count)
        }
        XCTAssertEqual(firstCount, 0)

        let secondCount = secondChunk.withUnsafeBufferPointer {
            utf8_decoder_decode(&decoder, $0.baseAddress, $0.count, &output, output.count)
        }
        XCTAssertEqual(Array(output.prefix(secondCount)), [0x3042, 0x42])
    }

    func testDecodeRejectsOverlongEncoding() {
        var decoder = Utf8Decoder()
        utf8_decoder_init(&decoder, true)

        let bytes: [UInt8] = [0xE0, 0x80, 0xAF]
        var output = [UInt32](repeating: 0, count: bytes.count)
        let count = bytes.withUnsafeBufferPointer {
            utf8_decoder_decode(&decoder, $0.baseAddress, $0.count, &output, output.count)
        }

        XCTAssertEqual(Array<UInt32>(output.prefix(count)), [
            UInt32(UTF8_REPLACEMENT_CHAR),
            UInt32(UTF8_REPLACEMENT_CHAR),
        ])
    }

    func testDecodeRejectsC1ControlsWhenConfigured() {
        var decoder = Utf8Decoder()
        utf8_decoder_init(&decoder, true)

        XCTAssertEqual(utf8_decoder_feed(&decoder, 0x9B), UInt32(UTF8_REJECT))
        XCTAssertEqual(decoder.codepoint, UInt32(UTF8_REPLACEMENT_CHAR))
        XCTAssertEqual(decoder.state, UInt32(UTF8_ACCEPT))
    }

    func testDecodeAllowsC1BytesWhenRejectionDisabled() {
        var decoder = Utf8Decoder()
        utf8_decoder_init(&decoder, false)

        XCTAssertNotEqual(utf8_decoder_feed(&decoder, 0xC2), UInt32(UTF8_REJECT))
        XCTAssertEqual(utf8_decoder_feed(&decoder, 0x9B), UInt32(UTF8_ACCEPT))
        XCTAssertEqual(decoder.codepoint, 0x9B)
    }

    func testDecodeASCIIPrefixStopsAtFirstNonASCIIByte() {
        let bytes: [UInt8] = [0x41, 0x42, 0x43, 0xE3, 0x81, 0x82]
        var output = [UInt32](repeating: 0, count: bytes.count)

        let count = bytes.withUnsafeBufferPointer {
            utf8_decoder_decode_ascii_prefix($0.baseAddress, $0.count, &output, output.count)
        }

        XCTAssertEqual(count, 3)
        XCTAssertEqual(Array(output.prefix(Int(count))), [0x41, 0x42, 0x43])
    }

    func testDecodeThreeBytePrefixDecodesContiguousCJKRun() {
        let bytes = Array("日本語かな".utf8) + [0x41]
        var output = [UInt32](repeating: 0, count: bytes.count)
        var bytesConsumed = 0

        let count = bytes.withUnsafeBufferPointer {
            utf8_decoder_decode_three_byte_prefix(
                $0.baseAddress,
                $0.count,
                &output,
                output.count,
                &bytesConsumed
            )
        }

        XCTAssertEqual(bytesConsumed, Array("日本語かな".utf8).count)
        XCTAssertEqual(count, 5)
        XCTAssertEqual(Array(output.prefix(Int(count))), [0x65E5, 0x672C, 0x8A9E, 0x304B, 0x306A])
    }

    func testDecodeCommonWideThreeBytePrefixStopsBeforeNarrowScalar() {
        let bytes = Array("日本€語".utf8)
        var output = [UInt32](repeating: 0, count: bytes.count)
        var bytesConsumed = 0

        let count = bytes.withUnsafeBufferPointer {
            utf8_decoder_decode_common_wide_three_byte_prefix(
                $0.baseAddress,
                $0.count,
                &output,
                output.count,
                &bytesConsumed
            )
        }

        XCTAssertEqual(bytesConsumed, Array("日本".utf8).count)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(Array(output.prefix(Int(count))), [0x65E5, 0x672C])
    }
}

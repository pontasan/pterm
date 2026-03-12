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
}

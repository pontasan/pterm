import XCTest
import PtermCore

private final class VTCollector {
    struct Event: Equatable {
        let actionRawValue: Int
        let codepoint: UInt32
        let params: [Int32]
        let stringData: String
    }

    var events: [Event] = []
}

private func vtTestCallback(_ parser: UnsafeMutablePointer<VtParser>?, _ action: VtParserAction, _ codepoint: UInt32, _ userData: UnsafeMutableRawPointer?) {
    guard let parser, let userData else { return }
    let collector = Unmanaged<VTCollector>.fromOpaque(userData).takeUnretainedValue()
    let paramCount = Int(parser.pointee.param_count)
    let params: [Int32] = withUnsafePointer(to: parser.pointee.params) { pointer in
        pointer.withMemoryRebound(to: Int32.self, capacity: paramCount) {
            Array(UnsafeBufferPointer(start: $0, count: paramCount))
        }
    }
    let stringData: String
    if let buffer = parser.pointee.string_buf, parser.pointee.string_len > 0 {
        stringData = String(decoding: UnsafeBufferPointer(start: buffer, count: parser.pointee.string_len), as: UTF8.self)
    } else {
        stringData = ""
    }
    collector.events.append(.init(actionRawValue: Int(action.rawValue), codepoint: codepoint, params: params, stringData: stringData))
}

final class VTParserTests: XCTestCase {
    func testPrintAndExecuteCallbacksAreEmitted() {
        let collector = VTCollector()
        var parser = VtParser()
        vt_parser_init(&parser, vtTestCallback, Unmanaged.passUnretained(collector).toOpaque())
        defer { vt_parser_destroy(&parser) }

        let input: [UInt32] = [UInt32(Character("A").unicodeScalars.first!.value), 0x0A]
        vt_parser_feed(&parser, input, input.count)

        XCTAssertEqual(collector.events.map(\.actionRawValue), [Int(VT_ACTION_PRINT.rawValue), Int(VT_ACTION_EXECUTE.rawValue)])
        XCTAssertEqual(collector.events.map(\.codepoint), [0x41, 0x0A])
    }

    func testCSISequenceParsesParametersAndDispatches() {
        let collector = VTCollector()
        var parser = VtParser()
        vt_parser_init(&parser, vtTestCallback, Unmanaged.passUnretained(collector).toOpaque())
        defer { vt_parser_destroy(&parser) }

        let input = Array("\u{001B}[12;34H".unicodeScalars).map(\.value)
        vt_parser_feed(&parser, input, input.count)

        let csiDispatch = collector.events.last { $0.actionRawValue == Int(VT_ACTION_CSI_DISPATCH.rawValue) }
        XCTAssertNotNil(csiDispatch)
        XCTAssertEqual(csiDispatch?.codepoint, UInt32(Character("H").unicodeScalars.first!.value))
        XCTAssertEqual(csiDispatch?.params, [12, 34])
        XCTAssertEqual(vt_parser_param(&parser, 0, 1), 12)
        XCTAssertEqual(vt_parser_param(&parser, 1, 1), 34)
        XCTAssertEqual(vt_parser_param(&parser, 2, 99), 99)
    }

    func testOSCSequenceAccumulatesStringAndEndsOnBEL() {
        let collector = VTCollector()
        var parser = VtParser()
        vt_parser_init(&parser, vtTestCallback, Unmanaged.passUnretained(collector).toOpaque())
        defer { vt_parser_destroy(&parser) }

        let input = Array("\u{001B}]0;title\u{0007}".unicodeScalars).map(\.value)
        vt_parser_feed(&parser, input, input.count)

        XCTAssertTrue(collector.events.contains { $0.actionRawValue == Int(VT_ACTION_OSC_START.rawValue) })
        let oscEnd = collector.events.last { $0.actionRawValue == Int(VT_ACTION_OSC_END.rawValue) }
        XCTAssertEqual(oscEnd?.stringData, "0;title")
        XCTAssertEqual(parser.state, VT_STATE_GROUND)
    }

    func testDCSSequenceEmitsHookPutAndUnhook() {
        let collector = VTCollector()
        var parser = VtParser()
        vt_parser_init(&parser, vtTestCallback, Unmanaged.passUnretained(collector).toOpaque())
        defer { vt_parser_destroy(&parser) }

        let input = Array("\u{001B}P1;2|abc\u{001B}\\".unicodeScalars).map(\.value)
        vt_parser_feed(&parser, input, input.count)

        XCTAssertTrue(collector.events.contains { $0.actionRawValue == Int(VT_ACTION_HOOK.rawValue) })
        XCTAssertTrue(collector.events.contains { $0.actionRawValue == Int(VT_ACTION_DCS_PUT.rawValue) && $0.codepoint == 0x61 })
        XCTAssertTrue(collector.events.contains { $0.actionRawValue == Int(VT_ACTION_UNHOOK.rawValue) })
        XCTAssertEqual(parser.state, VT_STATE_GROUND)
    }

    func testIgnoredOSCFastPathConsumesPayloadWithoutDecodingEachByte() {
        let collector = VTCollector()
        var parser = VtParser()
        vt_parser_init(&parser, vtTestCallback, Unmanaged.passUnretained(collector).toOpaque())
        defer { vt_parser_destroy(&parser) }

        let prefix = Array("\u{001B}]6;".utf8)
        let payload = Array(repeating: UInt8(ascii: "A"), count: 4096)
        let suffix = Array("\u{001B}\\".utf8)

        let prefixCodepoints = prefix.map(UInt32.init)
        vt_parser_feed(&parser, prefixCodepoints, prefixCodepoints.count)
        XCTAssertEqual(parser.state, VT_STATE_OSC_STRING)
        XCTAssertTrue(parser.osc_ignore_payload)

        let consumed = payload.withUnsafeBufferPointer {
            vt_parser_consume_ascii_ignored_string_fast_path(&parser, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(consumed, payload.count)
        XCTAssertEqual(parser.state, VT_STATE_OSC_STRING)

        let terminatorConsumed = suffix.withUnsafeBufferPointer {
            vt_parser_consume_ascii_ignored_string_fast_path(&parser, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(terminatorConsumed, suffix.count)
        XCTAssertEqual(parser.state, VT_STATE_GROUND)
        XCTAssertTrue(collector.events.contains { $0.actionRawValue == Int(VT_ACTION_OSC_END.rawValue) })
    }

    func testIgnoredAPCFastPathConsumesPayloadUntilST() {
        let collector = VTCollector()
        var parser = VtParser()
        vt_parser_init(&parser, vtTestCallback, Unmanaged.passUnretained(collector).toOpaque())
        defer { vt_parser_destroy(&parser) }

        let prefix = Array("\u{001B}_".utf8).map(UInt32.init)
        vt_parser_feed(&parser, prefix, prefix.count)
        XCTAssertEqual(parser.state, VT_STATE_SOS_PM_APC_STRING)

        let payload = Array(repeating: UInt8(ascii: "B"), count: 4096)
        let consumed = payload.withUnsafeBufferPointer {
            vt_parser_consume_ascii_ignored_string_fast_path(&parser, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(consumed, payload.count)
        XCTAssertEqual(parser.state, VT_STATE_SOS_PM_APC_STRING)

        let suffix = Array("\u{001B}\\".utf8)
        let suffixConsumed = suffix.withUnsafeBufferPointer {
            vt_parser_consume_ascii_ignored_string_fast_path(&parser, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(suffixConsumed, suffix.count)
        XCTAssertEqual(parser.state, VT_STATE_GROUND)
    }

    func testScanPrintableASCIIPrefixStopsAtControlByte() {
        let bytes: [UInt8] = Array("Hello, world!".utf8) + [0x0A, 0x41]
        let scanned = bytes.withUnsafeBufferPointer {
            vt_parser_scan_printable_ascii_prefix($0.baseAddress, $0.count)
        }
        XCTAssertEqual(scanned, 13)
    }

    func testScanTextASCIIPrefixIncludesWhitespaceControlsButStopsAtEscape() {
        let bytes: [UInt8] = Array("abc".utf8) + [0x09, 0x0A, 0x0D] + Array("xyz".utf8) + [0x1B, 0x5B]
        let scanned = bytes.withUnsafeBufferPointer {
            vt_parser_scan_text_ascii_prefix($0.baseAddress, $0.count)
        }
        XCTAssertEqual(scanned, 9)
    }
}

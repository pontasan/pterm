import Foundation
import PtermCore

enum TerminalTextEncoding: String {
    case utf8 = "utf-8"
    case utf16 = "utf-16"
    case utf16LittleEndian = "utf-16le"
    case utf16BigEndian = "utf-16be"

    init?(configuredValue: String) {
        let normalized = configuredValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "utf-8", "utf8":
            self = .utf8
        case "utf-16", "utf16":
            self = .utf16
        case "utf-16le", "utf16le":
            self = .utf16LittleEndian
        case "utf-16be", "utf16be":
            self = .utf16BigEndian
        default:
            return nil
        }
    }

    func encode(_ string: String) -> Data? {
        switch self {
        case .utf8:
            return Data(string.utf8)
        case .utf16, .utf16LittleEndian:
            return string.data(using: .utf16LittleEndian)
        case .utf16BigEndian:
            return string.data(using: .utf16BigEndian)
        }
    }

    func decode(_ data: Data) -> String? {
        let decoder = TerminalTextDecoder(encoding: self)
        var output = [UInt32](repeating: 0, count: max(data.count, 1))
        let count = data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return decoder.decode(bytes, into: &output)
        }
        return Self.string(from: output[0..<count])
    }

    static func string<S: Sequence>(from codepoints: S) -> String? where S.Element == UInt32 {
        var scalars = String.UnicodeScalarView()
        for codepoint in codepoints {
            guard let scalar = Unicode.Scalar(codepoint) else {
                scalars.append("\u{FFFD}")
                continue
            }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}

final class TerminalTextDecoder {
    private enum UTF16Endianness {
        case little
        case big
    }

    private let encoding: TerminalTextEncoding
    private var utf8Decoder = Utf8Decoder()
    private var pendingByte: UInt8?
    private var pendingHighSurrogate: UInt16?
    private var detectedEndianness: UTF16Endianness?
    private var bomProbe: [UInt8] = []

    init(encoding: TerminalTextEncoding) {
        self.encoding = encoding
        reset()
    }

    func reset() {
        utf8_decoder_init(&utf8Decoder, true)
        pendingByte = nil
        pendingHighSurrogate = nil
        bomProbe.removeAll(keepingCapacity: true)
        switch encoding {
        case .utf8:
            detectedEndianness = nil
        case .utf16:
            detectedEndianness = nil
        case .utf16LittleEndian:
            detectedEndianness = .little
        case .utf16BigEndian:
            detectedEndianness = .big
        }
    }

    func decode(_ input: UnsafeBufferPointer<UInt8>, into output: inout [UInt32]) -> Int {
        switch encoding {
        case .utf8:
            return utf8_decoder_decode(
                &utf8Decoder,
                input.baseAddress,
                input.count,
                &output,
                output.count
            )
        case .utf16, .utf16LittleEndian, .utf16BigEndian:
            return decodeUTF16(input, into: &output)
        }
    }

    private func decodeUTF16(_ input: UnsafeBufferPointer<UInt8>, into output: inout [UInt32]) -> Int {
        var outCount = 0

        func appendCodepoint(_ codepoint: UInt32) {
            guard outCount < output.count else { return }
            output[outCount] = codepoint
            outCount += 1
        }

        for byte in input {
            guard outCount < output.count else { break }

            if encoding == .utf16, detectedEndianness == nil {
                bomProbe.append(byte)
                if bomProbe.count < 2 {
                    continue
                }

                if bomProbe[0] == 0xFF && bomProbe[1] == 0xFE {
                    detectedEndianness = .little
                    bomProbe.removeAll(keepingCapacity: true)
                    continue
                }

                if bomProbe[0] == 0xFE && bomProbe[1] == 0xFF {
                    detectedEndianness = .big
                    bomProbe.removeAll(keepingCapacity: true)
                    continue
                }

                detectedEndianness = .little
                let codeUnit = makeCodeUnit(first: bomProbe[0], second: bomProbe[1], endianness: .little)
                bomProbe.removeAll(keepingCapacity: true)
                append(codeUnit: codeUnit, appendCodepoint: appendCodepoint)
                continue
            }

            if let first = pendingByte {
                pendingByte = nil
                let endianness = detectedEndianness ?? .little
                let codeUnit = makeCodeUnit(first: first, second: byte, endianness: endianness)
                append(codeUnit: codeUnit, appendCodepoint: appendCodepoint)
            } else {
                pendingByte = byte
            }
        }

        return outCount
    }

    private func makeCodeUnit(first: UInt8, second: UInt8, endianness: UTF16Endianness) -> UInt16 {
        switch endianness {
        case .little:
            return UInt16(first) | (UInt16(second) << 8)
        case .big:
            return (UInt16(first) << 8) | UInt16(second)
        }
    }

    private func append(codeUnit: UInt16, appendCodepoint: (UInt32) -> Void) {
        switch codeUnit {
        case 0xD800...0xDBFF:
            if pendingHighSurrogate != nil {
                appendCodepoint(0xFFFD)
            }
            pendingHighSurrogate = codeUnit

        case 0xDC00...0xDFFF:
            guard let high = pendingHighSurrogate else {
                appendCodepoint(0xFFFD)
                return
            }
            pendingHighSurrogate = nil
            let scalar = 0x10000
                + ((UInt32(high - 0xD800) << 10) | UInt32(codeUnit - 0xDC00))
            appendCodepoint(scalar)

        default:
            if pendingHighSurrogate != nil {
                appendCodepoint(0xFFFD)
                pendingHighSurrogate = nil
            }
            appendCodepoint(UInt32(codeUnit))
        }
    }
}

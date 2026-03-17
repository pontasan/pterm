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
        return decoder.decode(data)
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
    private enum DecodeBufferPolicy {
        static let minimumCapacity = 256
    }

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
    private var decodeBuffer: [UInt32] = []

    init(encoding: TerminalTextEncoding) {
        self.encoding = encoding
        reset()
    }

    func reset() {
        // Terminals must preserve 8-bit C1 controls such as CSI (0x9B),
        // DCS (0x90), OSC (0x9D), and ST (0x9C). kitty's benchmark and
        // vttest both exercise these paths. The core decoder still supports
        // a strict "reject C1" mode for non-terminal use, but terminal input
        // decoding must pass them through so the VT parser can interpret them.
        utf8_decoder_init(&utf8Decoder, false)
        pendingByte = nil
        pendingHighSurrogate = nil
        bomProbe.removeAll(keepingCapacity: false)
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

    var debugDecodeBufferCapacity: Int {
        decodeBuffer.count
    }

    var debugBOMProbeCapacity: Int {
        bomProbe.count
    }

    var canDecodeDirectASCII: Bool {
        encoding == .utf8 && utf8Decoder.state == UTF8_ACCEPT
    }

    func decode(_ data: Data) -> String? {
        ensureDecodeBufferCapacity(requiredCount: max(data.count, 1))
        let count = data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return decode(bytes, into: &decodeBuffer)
        }
        shrinkIdleDecodeBufferIfNeeded(requiredCount: count)
        return TerminalTextEncoding.string(from: decodeBuffer[0..<count])
    }

    func debugPrimeDecodeBufferCapacity(_ requiredCount: Int) {
        ensureDecodeBufferCapacity(requiredCount: requiredCount)
    }

    func debugShrinkDecodeBufferIfIdle(requiredCount: Int = 0) {
        shrinkIdleDecodeBufferIfNeeded(requiredCount: requiredCount)
    }

    func debugPrimeBOMProbeCapacity(_ byteCount: Int) {
        bomProbe = [UInt8](repeating: 0, count: byteCount)
    }

    private func ensureDecodeBufferCapacity(requiredCount: Int) {
        let normalizedCount = max(DecodeBufferPolicy.minimumCapacity, requiredCount)
        guard decodeBuffer.count < normalizedCount else { return }
        var newCapacity = max(DecodeBufferPolicy.minimumCapacity, decodeBuffer.count)
        while newCapacity < normalizedCount {
            newCapacity = max(newCapacity * 2, normalizedCount)
        }
        decodeBuffer = [UInt32](repeating: 0, count: newCapacity)
    }

    private func shrinkIdleDecodeBufferIfNeeded(requiredCount: Int) {
        guard requiredCount > 0 else {
            guard !decodeBuffer.isEmpty else { return }
            decodeBuffer.removeAll(keepingCapacity: false)
            return
        }
        let target = max(DecodeBufferPolicy.minimumCapacity, requiredCount)
        guard decodeBuffer.count > target * 2 else { return }
        decodeBuffer = [UInt32](repeating: 0, count: target)
    }

    func decode(_ input: UnsafeBufferPointer<UInt8>, into output: inout [UInt32]) -> Int {
        switch encoding {
        case .utf8:
            if utf8Decoder.state == UTF8_ACCEPT,
               let asciiCount = decodeASCIIIfPossible(input, into: &output) {
                return asciiCount
            }
            return decodeUTF8(input, into: &output)
        case .utf16, .utf16LittleEndian, .utf16BigEndian:
            return decodeUTF16(input, into: &output)
        }
    }

    private func decodeASCIIIfPossible(_ input: UnsafeBufferPointer<UInt8>, into output: inout [UInt32]) -> Int? {
        guard input.count <= output.count else { return nil }
        for byte in input where byte >= 0x80 {
            return nil
        }
        for (index, byte) in input.enumerated() {
            output[index] = UInt32(byte)
        }
        return input.count
    }

    private func decodeUTF8(_ input: UnsafeBufferPointer<UInt8>, into output: inout [UInt32]) -> Int {
        var outCount = 0
        var index = 0

        while index < input.count {
            guard outCount < output.count else { break }
            let byte = input[index]

            // Preserve raw 8-bit C1 controls when they occur at codepoint
            // boundaries. Terminals must recognize these as control functions,
            // not replacement glyphs.
            if utf8Decoder.state == UTF8_ACCEPT, byte >= 0x80, byte <= 0x9F {
                output[outCount] = UInt32(byte)
                outCount += 1
                index += 1
                continue
            }

            if utf8Decoder.state == UTF8_ACCEPT {
                if byte < 0x80 {
                    output[outCount] = UInt32(byte)
                    outCount += 1
                    index += 1
                    continue
                }

                if byte >= 0xC2, byte <= 0xDF, index + 1 < input.count {
                    let b1 = input[index + 1]
                    if b1 & 0xC0 == 0x80 {
                        output[outCount] = (UInt32(byte & 0x1F) << 6) | UInt32(b1 & 0x3F)
                        outCount += 1
                        index += 2
                        continue
                    }
                }

                if byte >= 0xE0, byte <= 0xEF, index + 2 < input.count {
                    let b1 = input[index + 1]
                    let b2 = input[index + 2]
                    let isLegalSecondByte =
                        (byte == 0xE0 && (0xA0...0xBF).contains(b1)) ||
                        (byte == 0xED && (0x80...0x9F).contains(b1)) ||
                        ((byte != 0xE0 && byte != 0xED) && (b1 & 0xC0 == 0x80))
                    if isLegalSecondByte, b2 & 0xC0 == 0x80 {
                        output[outCount] =
                            (UInt32(byte & 0x0F) << 12) |
                            (UInt32(b1 & 0x3F) << 6) |
                            UInt32(b2 & 0x3F)
                        outCount += 1
                        index += 3
                        continue
                    }
                }

                if byte >= 0xF0, byte <= 0xF4, index + 3 < input.count {
                    let b1 = input[index + 1]
                    let b2 = input[index + 2]
                    let b3 = input[index + 3]
                    let isLegalSecondByte =
                        (byte == 0xF0 && (0x90...0xBF).contains(b1)) ||
                        (byte == 0xF4 && (0x80...0x8F).contains(b1)) ||
                        ((byte != 0xF0 && byte != 0xF4) && (b1 & 0xC0 == 0x80))
                    if isLegalSecondByte, b2 & 0xC0 == 0x80, b3 & 0xC0 == 0x80 {
                        output[outCount] =
                            (UInt32(byte & 0x07) << 18) |
                            (UInt32(b1 & 0x3F) << 12) |
                            (UInt32(b2 & 0x3F) << 6) |
                            UInt32(b3 & 0x3F)
                        outCount += 1
                        index += 4
                        continue
                    }
                }
            }

            let result = utf8_decoder_feed(&utf8Decoder, byte)
            if result == UTF8_ACCEPT {
                output[outCount] = utf8Decoder.codepoint
                outCount += 1
            } else if result == UTF8_REJECT {
                output[outCount] = UInt32(UTF8_REPLACEMENT_CHAR)
                outCount += 1
            }
            index += 1
        }

        return outCount
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
                    bomProbe.removeAll(keepingCapacity: false)
                    continue
                }

                if bomProbe[0] == 0xFE && bomProbe[1] == 0xFF {
                    detectedEndianness = .big
                    bomProbe.removeAll(keepingCapacity: false)
                    continue
                }

                detectedEndianness = .little
                let codeUnit = makeCodeUnit(first: bomProbe[0], second: bomProbe[1], endianness: .little)
                bomProbe.removeAll(keepingCapacity: false)
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

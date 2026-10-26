import Foundation

/// Encodes xterm-compatible mouse reports sent to the PTY when the foreground
/// program has enabled mouse tracking (DECSET 9 / 1000 / 1002 / 1003).
///
/// Encoding follows xterm's ctlseqs:
/// - Cb: button 0/1/2, wheel 64/65, +32 for motion; legacy release is 3.
/// - Motion with no button pressed reports button 3 (Cb = 35).
/// - Legacy (X10) coordinates are single bytes `32 + position` (1-based), so
///   positions beyond 223 cannot be represented and are not reported.
/// - UTF-8 (1005) coordinates use the same value encoded as a UTF-8 scalar.
/// - SGR (1006) uses decimal parameters and `M` / `m` for press / release.
enum MouseReportEncoder {
    enum Phase: Equatable {
        case press
        case release
        case drag
        case motion
        case wheel
    }

    /// Button code reported for motion while no button is held.
    static let noButton = 3

    private static let legacyCoordinateLimit = 255 - 32
    private static let utf8CoordinateLimit = 2047 - 32

    /// - Parameters:
    ///   - button: 0 (left), 1 (middle), 2 (right), 64/65 (wheel). Ignored for
    ///     `.motion`, which always reports `noButton`.
    ///   - column: 0-based grid column.
    ///   - row: 0-based grid row.
    /// - Returns: The report bytes, or `nil` when the protocol cannot represent
    ///   the position (xterm drops such events instead of sending garbage).
    static func encode(button: Int,
                       column: Int,
                       row: Int,
                       phase: Phase,
                       protocolMode: TerminalModel.MouseProtocol) -> Data? {
        precondition(column >= 0 && row >= 0, "Mouse report position must be non-negative")
        let x = column + 1
        let y = row + 1

        switch protocolMode {
        case .sgr:
            let code: Int
            switch phase {
            case .press, .release, .wheel:
                code = button
            case .drag:
                code = button | 32
            case .motion:
                code = noButton | 32
            }
            let suffix = phase == .release ? "m" : "M"
            return Data("\u{1B}[<\(code);\(x);\(y)\(suffix)".utf8)
        case .x10, .utf8:
            let code: Int
            switch phase {
            case .press, .wheel:
                code = button
            case .release:
                code = noButton
            case .drag:
                code = button | 32
            case .motion:
                code = noButton | 32
            }
            var bytes: [UInt8] = [0x1B, 0x5B, 0x4D, UInt8(32 + code)]
            if protocolMode == .x10 {
                guard x <= legacyCoordinateLimit, y <= legacyCoordinateLimit else { return nil }
                bytes.append(UInt8(32 + x))
                bytes.append(UInt8(32 + y))
            } else {
                guard x <= utf8CoordinateLimit, y <= utf8CoordinateLimit else { return nil }
                appendUTF8(32 + x, to: &bytes)
                appendUTF8(32 + y, to: &bytes)
            }
            return Data(bytes)
        }
    }

    private static func appendUTF8(_ value: Int, to bytes: inout [UInt8]) {
        if value < 0x80 {
            bytes.append(UInt8(value))
        } else {
            bytes.append(UInt8(0xC0 | (value >> 6)))
            bytes.append(UInt8(0x80 | (value & 0x3F)))
        }
    }
}

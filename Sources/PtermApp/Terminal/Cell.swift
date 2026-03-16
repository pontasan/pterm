import Foundation

/// A single cell in the terminal grid.
/// Each cell holds one character (codepoint), its visual attributes, and display width.
struct Cell {
    /// Unicode codepoint. 0 means empty cell.
    var codepoint: UInt32

    /// Visual attributes (colors, bold, etc.)
    var attributes: CellAttributes

    /// Display width: 1 for normal, 2 for CJK/emoji, 0 for continuation of wide char
    var width: UInt8

    /// Whether this cell is the second half of a double-width character
    var isWideContinuation: Bool

    static let empty = Cell(
        codepoint: 0x20, // space
        attributes: .default,
        width: 1,
        isWideContinuation: false
    )
}

/// SGR (Select Graphic Rendition) attributes for a cell.
struct CellAttributes: Equatable {
    var foreground: TerminalColor
    var background: TerminalColor
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var strikethrough: Bool
    var inverse: Bool
    var hidden: Bool
    var dim: Bool
    var blink: Bool
    var decProtected: Bool = false

    static let `default` = CellAttributes(
        foreground: .default,
        background: .default,
        bold: false,
        italic: false,
        underline: false,
        strikethrough: false,
        inverse: false,
        hidden: false,
        dim: false,
        blink: false,
        decProtected: false
    )
}

/// Terminal color representation.
/// Supports default, indexed (0-255), and TrueColor (24-bit RGB).
enum TerminalColor: Equatable {
    case `default`
    case indexed(UInt8)          // 0-255 color index
    case rgb(UInt8, UInt8, UInt8) // 24-bit TrueColor

    var isDefaultColor: Bool {
        if case .default = self {
            return true
        }
        return false
    }

    /// Standard ANSI 16 color palette (dark theme defaults)
    static let ansiPalette: [(r: UInt8, g: UInt8, b: UInt8)] = [
        // Normal colors (0-7)
        (0x00, 0x00, 0x00), // Black
        (0xCD, 0x3A, 0x3A), // Red
        (0x2D, 0xCC, 0x2D), // Green
        (0xCC, 0xCC, 0x2D), // Yellow
        (0x3A, 0x3A, 0xCD), // Blue
        (0xCC, 0x2D, 0xCC), // Magenta
        (0x2D, 0xCC, 0xCC), // Cyan
        (0xCC, 0xCC, 0xCC), // White
        // Bright colors (8-15)
        (0x66, 0x66, 0x66), // Bright Black
        (0xFF, 0x54, 0x54), // Bright Red
        (0x54, 0xFF, 0x54), // Bright Green
        (0xFF, 0xFF, 0x54), // Bright Yellow
        (0x54, 0x54, 0xFF), // Bright Blue
        (0xFF, 0x54, 0xFF), // Bright Magenta
        (0x54, 0xFF, 0xFF), // Bright Cyan
        (0xFF, 0xFF, 0xFF), // Bright White
    ]

    /// Resolve to RGB values for rendering.
    func resolve(isForeground: Bool) -> (r: Float, g: Float, b: Float) {
        switch self {
        case .default:
            return isForeground ? (0.8, 0.8, 0.8) : (0.0, 0.0, 0.0)
        case .indexed(let idx):
            if idx < 16 {
                let c = TerminalColor.ansiPalette[Int(idx)]
                return (Float(c.r) / 255.0, Float(c.g) / 255.0, Float(c.b) / 255.0)
            } else if idx < 232 {
                // 6x6x6 color cube (indices 16-231)
                let val = Int(idx) - 16
                let r = val / 36
                let g = (val % 36) / 6
                let b = val % 6
                return (
                    r == 0 ? 0.0 : Float(r * 40 + 55) / 255.0,
                    g == 0 ? 0.0 : Float(g * 40 + 55) / 255.0,
                    b == 0 ? 0.0 : Float(b * 40 + 55) / 255.0
                )
            } else {
                // Grayscale (indices 232-255)
                let v = Float(Int(idx - 232) * 10 + 8) / 255.0
                return (v, v, v)
            }
        case .rgb(let r, let g, let b):
            return (Float(r) / 255.0, Float(g) / 255.0, Float(b) / 255.0)
        }
    }
}

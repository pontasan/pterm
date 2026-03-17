import Foundation

enum TerminalLineAttribute: Equatable {
    case singleWidth
    case doubleWidth
    case doubleHeightTop
    case doubleHeightBottom

    var isDoubleWidth: Bool {
        switch self {
        case .singleWidth:
            return false
        case .doubleWidth, .doubleHeightTop, .doubleHeightBottom:
            return true
        }
    }
}

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

    /// Inline image metadata. A value of 0 means this cell is plain text.
    var imageID: UInt32 = 0
    var imageColumns: UInt16 = 0
    var imageRows: UInt16 = 0
    var imageOriginColOffset: UInt16 = 0
    var imageOriginRowOffset: UInt16 = 0

    /// Fixed-size grapheme tail for combined emoji / combining sequences.
    /// The anchor scalar remains in `codepoint`; these slots hold trailing scalars.
    var graphemeTailCount: UInt8 = 0
    var graphemeTail0: UInt32 = 0
    var graphemeTail1: UInt32 = 0
    var graphemeTail2: UInt32 = 0
    var graphemeTail3: UInt32 = 0
    var graphemeTail4: UInt32 = 0
    var graphemeTail5: UInt32 = 0
    var graphemeTail6: UInt32 = 0

    var hasInlineImage: Bool {
        imageID != 0
    }

    var hasGraphemeTail: Bool {
        graphemeTailCount > 0
    }

    static let empty = Cell(
        codepoint: 0x20, // space
        attributes: .default,
        width: 1,
        isWideContinuation: false,
        imageID: 0,
        imageColumns: 0,
        imageRows: 0,
        imageOriginColOffset: 0,
        imageOriginRowOffset: 0,
        graphemeTailCount: 0,
        graphemeTail0: 0,
        graphemeTail1: 0,
        graphemeTail2: 0,
        graphemeTail3: 0,
        graphemeTail4: 0,
        graphemeTail5: 0,
        graphemeTail6: 0
    )

    static func inlineImage(
        id: Int,
        columns: Int,
        rows: Int,
        originColOffset: Int,
        originRowOffset: Int
    ) -> Cell {
        Cell(
            codepoint: 0x20,
            attributes: .default,
            width: 1,
            isWideContinuation: false,
            imageID: UInt32(max(id, 0)),
            imageColumns: UInt16(max(columns, 0)),
            imageRows: UInt16(max(rows, 0)),
            imageOriginColOffset: UInt16(max(originColOffset, 0)),
            imageOriginRowOffset: UInt16(max(originRowOffset, 0)),
            graphemeTailCount: 0,
            graphemeTail0: 0,
            graphemeTail1: 0,
            graphemeTail2: 0,
            graphemeTail3: 0,
            graphemeTail4: 0,
            graphemeTail5: 0,
            graphemeTail6: 0
        )
    }

    mutating func appendGraphemeScalar(_ codepoint: UInt32) -> Bool {
        switch graphemeTailCount {
        case 0: graphemeTail0 = codepoint
        case 1: graphemeTail1 = codepoint
        case 2: graphemeTail2 = codepoint
        case 3: graphemeTail3 = codepoint
        case 4: graphemeTail4 = codepoint
        case 5: graphemeTail5 = codepoint
        case 6: graphemeTail6 = codepoint
        default: return false
        }
        graphemeTailCount &+= 1
        return true
    }

    func graphemeScalars() -> [UInt32] {
        guard hasGraphemeTail else { return [codepoint] }
        var scalars = [UInt32]()
        scalars.reserveCapacity(1 + Int(graphemeTailCount))
        scalars.append(codepoint)
        if graphemeTailCount >= 1 { scalars.append(graphemeTail0) }
        if graphemeTailCount >= 2 { scalars.append(graphemeTail1) }
        if graphemeTailCount >= 3 { scalars.append(graphemeTail2) }
        if graphemeTailCount >= 4 { scalars.append(graphemeTail3) }
        if graphemeTailCount >= 5 { scalars.append(graphemeTail4) }
        if graphemeTailCount >= 6 { scalars.append(graphemeTail5) }
        if graphemeTailCount >= 7 { scalars.append(graphemeTail6) }
        return scalars
    }

    func renderedString() -> String {
        if hasInlineImage {
            return ""
        }
        return TerminalTextEncoding.string(from: graphemeScalars()) ?? ""
    }

    func lastGraphemeScalar() -> UInt32 {
        switch graphemeTailCount {
        case 0: return codepoint
        case 1: return graphemeTail0
        case 2: return graphemeTail1
        case 3: return graphemeTail2
        case 4: return graphemeTail3
        case 5: return graphemeTail4
        case 6: return graphemeTail5
        default: return graphemeTail6
        }
    }
}

enum UnderlineStyle: UInt8, Equatable {
    case single = 0
    case double = 1
    case curly = 2
    case dotted = 3
    case dashed = 4
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
    var underlineStyle: UnderlineStyle = .single
    var underlineColor: TerminalColor = .default

    init(
        foreground: TerminalColor,
        background: TerminalColor,
        bold: Bool,
        italic: Bool,
        underline: Bool,
        strikethrough: Bool,
        inverse: Bool,
        hidden: Bool,
        dim: Bool,
        blink: Bool,
        decProtected: Bool = false,
        underlineStyle: UnderlineStyle = .single,
        underlineColor: TerminalColor = .default
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.inverse = inverse
        self.hidden = hidden
        self.dim = dim
        self.blink = blink
        self.decProtected = decProtected
        self.underlineStyle = underlineStyle
        self.underlineColor = underlineColor
    }

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
        decProtected: false,
        underlineStyle: .single,
        underlineColor: .default
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

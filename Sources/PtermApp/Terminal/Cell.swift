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
    struct GraphemeCacheKey: Hashable {
        var count: UInt8
        var scalar0: UInt32
        var scalar1: UInt32
        var scalar2: UInt32
        var scalar3: UInt32
        var scalar4: UInt32
        var scalar5: UInt32
        var scalar6: UInt32
        var scalar7: UInt32

        init(
            count: UInt8,
            scalar0: UInt32,
            scalar1: UInt32,
            scalar2: UInt32,
            scalar3: UInt32,
            scalar4: UInt32,
            scalar5: UInt32,
            scalar6: UInt32,
            scalar7: UInt32
        ) {
            self.count = count
            self.scalar0 = scalar0
            self.scalar1 = scalar1
            self.scalar2 = scalar2
            self.scalar3 = scalar3
            self.scalar4 = scalar4
            self.scalar5 = scalar5
            self.scalar6 = scalar6
            self.scalar7 = scalar7
        }

        func renderedString() -> String {
            let scalars: [UInt32] = switch count {
            case 1: [scalar0]
            case 2: [scalar0, scalar1]
            case 3: [scalar0, scalar1, scalar2]
            case 4: [scalar0, scalar1, scalar2, scalar3]
            case 5: [scalar0, scalar1, scalar2, scalar3, scalar4]
            case 6: [scalar0, scalar1, scalar2, scalar3, scalar4, scalar5]
            case 7: [scalar0, scalar1, scalar2, scalar3, scalar4, scalar5, scalar6]
            default: [scalar0, scalar1, scalar2, scalar3, scalar4, scalar5, scalar6, scalar7]
            }
            return TerminalTextEncoding.string(from: scalars) ?? ""
        }

        static func isOrdered(_ lhs: GraphemeCacheKey, _ rhs: GraphemeCacheKey) -> Bool {
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            if lhs.scalar0 != rhs.scalar0 { return lhs.scalar0 < rhs.scalar0 }
            if lhs.scalar1 != rhs.scalar1 { return lhs.scalar1 < rhs.scalar1 }
            if lhs.scalar2 != rhs.scalar2 { return lhs.scalar2 < rhs.scalar2 }
            if lhs.scalar3 != rhs.scalar3 { return lhs.scalar3 < rhs.scalar3 }
            if lhs.scalar4 != rhs.scalar4 { return lhs.scalar4 < rhs.scalar4 }
            if lhs.scalar5 != rhs.scalar5 { return lhs.scalar5 < rhs.scalar5 }
            if lhs.scalar6 != rhs.scalar6 { return lhs.scalar6 < rhs.scalar6 }
            return lhs.scalar7 < rhs.scalar7
        }
    }

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

    @inline(__always)
    func graphemeScalarCount() -> Int {
        1 + Int(graphemeTailCount)
    }

    @inline(__always)
    func onlyScalarMatches(_ predicate: (UInt32) -> Bool) -> Bool {
        guard graphemeTailCount == 0 else { return false }
        return predicate(codepoint)
    }

    @inline(__always)
    func containsGraphemeScalar(_ scalar: UInt32) -> Bool {
        if codepoint == scalar { return true }
        if graphemeTailCount >= 1, graphemeTail0 == scalar { return true }
        if graphemeTailCount >= 2, graphemeTail1 == scalar { return true }
        if graphemeTailCount >= 3, graphemeTail2 == scalar { return true }
        if graphemeTailCount >= 4, graphemeTail3 == scalar { return true }
        if graphemeTailCount >= 5, graphemeTail4 == scalar { return true }
        if graphemeTailCount >= 6, graphemeTail5 == scalar { return true }
        if graphemeTailCount >= 7, graphemeTail6 == scalar { return true }
        return false
    }

    @inline(__always)
    func containsGraphemeScalar(where predicate: (UInt32) -> Bool) -> Bool {
        if predicate(codepoint) { return true }
        if graphemeTailCount >= 1, predicate(graphemeTail0) { return true }
        if graphemeTailCount >= 2, predicate(graphemeTail1) { return true }
        if graphemeTailCount >= 3, predicate(graphemeTail2) { return true }
        if graphemeTailCount >= 4, predicate(graphemeTail3) { return true }
        if graphemeTailCount >= 5, predicate(graphemeTail4) { return true }
        if graphemeTailCount >= 6, predicate(graphemeTail5) { return true }
        if graphemeTailCount >= 7, predicate(graphemeTail6) { return true }
        return false
    }

    func renderedString() -> String {
        if hasInlineImage {
            return ""
        }
        return TerminalTextEncoding.string(from: graphemeScalars()) ?? ""
    }

    @inline(__always)
    func graphemeCacheKey() -> GraphemeCacheKey? {
        guard !hasInlineImage else { return nil }
        return GraphemeCacheKey(
            count: graphemeTailCount &+ 1,
            scalar0: codepoint,
            scalar1: graphemeTail0,
            scalar2: graphemeTail1,
            scalar3: graphemeTail2,
            scalar4: graphemeTail3,
            scalar5: graphemeTail4,
            scalar6: graphemeTail5,
            scalar7: graphemeTail6
        )
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

    @inline(__always)
    func mayUseColorEmojiPresentation() -> Bool {
        guard !hasInlineImage, codepoint > 0x20 else { return false }
        if !hasGraphemeTail {
            guard Cell.scalarMayHaveDefaultEmojiPresentation(codepoint),
                  let scalar = UnicodeScalar(codepoint) else { return false }
            return scalar.properties.isEmojiPresentation
        }

        if Cell.scalarRequiresColorEmojiConsideration(codepoint) { return true }
        if graphemeTailCount >= 1, Cell.scalarRequiresColorEmojiConsideration(graphemeTail0) { return true }
        if graphemeTailCount >= 2, Cell.scalarRequiresColorEmojiConsideration(graphemeTail1) { return true }
        if graphemeTailCount >= 3, Cell.scalarRequiresColorEmojiConsideration(graphemeTail2) { return true }
        if graphemeTailCount >= 4, Cell.scalarRequiresColorEmojiConsideration(graphemeTail3) { return true }
        if graphemeTailCount >= 5, Cell.scalarRequiresColorEmojiConsideration(graphemeTail4) { return true }
        if graphemeTailCount >= 6, Cell.scalarRequiresColorEmojiConsideration(graphemeTail5) { return true }
        if graphemeTailCount >= 7, Cell.scalarRequiresColorEmojiConsideration(graphemeTail6) { return true }
        return false
    }

    @inline(__always)
    private static func scalarRequiresColorEmojiConsideration(_ scalarValue: UInt32) -> Bool {
        if scalarValue == 0x200D || scalarValue == 0xFE0F || scalarValue == 0x20E3 {
            return true
        }
        if (0x1F1E6...0x1F1FF).contains(scalarValue) || (0x1F3FB...0x1F3FF).contains(scalarValue) {
            return true
        }
        guard scalarMayHaveDefaultEmojiPresentation(scalarValue),
              let scalar = UnicodeScalar(scalarValue) else { return false }
        return scalar.properties.isEmojiPresentation
    }

    @inline(__always)
    private static func scalarMayHaveDefaultEmojiPresentation(_ scalarValue: UInt32) -> Bool {
        if scalarValue >= 0x1F000 {
            return true
        }
        switch scalarValue {
        case 0x231A...0x231B,
             0x23E9...0x23EC,
             0x23F0, 0x23F3,
             0x24C2,
             0x25FD...0x25FE,
             0x2614...0x2615,
             0x2648...0x2653,
             0x267F,
             0x2693,
             0x26A1,
             0x26AA...0x26AB,
             0x26BD...0x26BE,
             0x26C4...0x26C5,
             0x26CE,
             0x26D4,
             0x26EA,
             0x26F2...0x26F5,
             0x26FA,
             0x26FD,
             0x2705,
             0x270A...0x270B,
             0x2728,
             0x274C,
             0x274E,
             0x2753...0x2755,
             0x2757,
             0x2795...0x2797,
             0x27B0,
             0x27BF,
             0x2B1B...0x2B1C,
             0x2B50,
             0x2B55:
            return true
        default:
            return false
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
    var underlineColor: TerminalColor = .default
    private var packedFlags: UInt16

    private static let boldBit: UInt16 = 1 << 0
    private static let italicBit: UInt16 = 1 << 1
    private static let underlineBit: UInt16 = 1 << 2
    private static let strikethroughBit: UInt16 = 1 << 3
    private static let inverseBit: UInt16 = 1 << 4
    private static let hiddenBit: UInt16 = 1 << 5
    private static let dimBit: UInt16 = 1 << 6
    private static let blinkBit: UInt16 = 1 << 7
    private static let decProtectedBit: UInt16 = 1 << 8
    private static let underlineStyleShift: UInt16 = 9
    private static let underlineStyleMask: UInt16 = 0b111 << underlineStyleShift

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
        self.underlineColor = underlineColor
        var flags: UInt16 = 0
        if bold { flags |= Self.boldBit }
        if italic { flags |= Self.italicBit }
        if underline { flags |= Self.underlineBit }
        if strikethrough { flags |= Self.strikethroughBit }
        if inverse { flags |= Self.inverseBit }
        if hidden { flags |= Self.hiddenBit }
        if dim { flags |= Self.dimBit }
        if blink { flags |= Self.blinkBit }
        if decProtected { flags |= Self.decProtectedBit }
        flags |= UInt16(underlineStyle.rawValue) << Self.underlineStyleShift
        self.packedFlags = flags
    }

    var bold: Bool {
        get { (packedFlags & Self.boldBit) != 0 }
        set { setFlag(Self.boldBit, enabled: newValue) }
    }

    var italic: Bool {
        get { (packedFlags & Self.italicBit) != 0 }
        set { setFlag(Self.italicBit, enabled: newValue) }
    }

    var underline: Bool {
        get { (packedFlags & Self.underlineBit) != 0 }
        set { setFlag(Self.underlineBit, enabled: newValue) }
    }

    var strikethrough: Bool {
        get { (packedFlags & Self.strikethroughBit) != 0 }
        set { setFlag(Self.strikethroughBit, enabled: newValue) }
    }

    var inverse: Bool {
        get { (packedFlags & Self.inverseBit) != 0 }
        set { setFlag(Self.inverseBit, enabled: newValue) }
    }

    var hidden: Bool {
        get { (packedFlags & Self.hiddenBit) != 0 }
        set { setFlag(Self.hiddenBit, enabled: newValue) }
    }

    var dim: Bool {
        get { (packedFlags & Self.dimBit) != 0 }
        set { setFlag(Self.dimBit, enabled: newValue) }
    }

    var blink: Bool {
        get { (packedFlags & Self.blinkBit) != 0 }
        set { setFlag(Self.blinkBit, enabled: newValue) }
    }

    var decProtected: Bool {
        get { (packedFlags & Self.decProtectedBit) != 0 }
        set { setFlag(Self.decProtectedBit, enabled: newValue) }
    }

    var underlineStyle: UnderlineStyle {
        get {
            let rawValue = UInt8((packedFlags & Self.underlineStyleMask) >> Self.underlineStyleShift)
            return UnderlineStyle(rawValue: rawValue) ?? .single
        }
        set {
            packedFlags &= ~Self.underlineStyleMask
            packedFlags |= UInt16(newValue.rawValue) << Self.underlineStyleShift
        }
    }

    private mutating func setFlag(_ bit: UInt16, enabled: Bool) {
        if enabled {
            packedFlags |= bit
        } else {
            packedFlags &= ~bit
        }
    }

    static func == (lhs: CellAttributes, rhs: CellAttributes) -> Bool {
        lhs.foreground == rhs.foreground &&
        lhs.background == rhs.background &&
        lhs.underlineColor == rhs.underlineColor &&
        lhs.packedFlags == rhs.packedFlags
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

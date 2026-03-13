import Foundation
import PtermCore

/// Core terminal emulation model.
///
/// Owns the character grid and cursor state. Processes VT parser actions
/// to update the terminal display. This is the bridge between the C VT parser
/// and the Swift rendering layer.
final class TerminalModel {
    private enum DesignatedCharacterSet {
        case ascii
        case decSpecialGraphics
    }

    private enum TitleUpdateRateLimit {
        static let interval: TimeInterval = 1.0
        static let maxUpdatesPerInterval = 8
    }

    /// Active screen grid
    private(set) var grid: TerminalGrid

    /// Alternate screen grid (for full-screen apps like vim)
    private var alternateGrid: TerminalGrid?

    /// Whether we're currently using the alternate screen
    private(set) var isAlternateScreen: Bool = false

    /// Cursor state
    var cursor: CursorState = CursorState()

    /// Terminal dimensions
    private(set) var rows: Int
    private(set) var cols: Int

    /// Bracketed paste mode
    var bracketedPasteMode: Bool = false

    /// Application cursor keys mode (DECCKM)
    var applicationCursorKeys: Bool = false

    /// Mouse reporting mode
    var mouseReporting: MouseReportingMode = .none

    /// Window title
    private(set) var title: String = ""

    /// Tab stops stored as a compact bitset to keep per-terminal overhead low.
    private var tabStopWords: [UInt64] = []

    /// G0/G1 character set designations and the currently invoked set.
    private var g0Charset: DesignatedCharacterSet = .ascii
    private var g1Charset: DesignatedCharacterSet = .ascii
    private var activeCharsetIsG1 = false

    /// Callback when a line scrolls off the top of the screen (for scrollback)
    var onScrollOut: ((_ cells: [Cell], _ isWrapped: Bool) -> Void)?

    /// Callback when title changes
    var onTitleChange: ((String) -> Void)?

    /// Callback when bell is triggered
    var onBell: (() -> Void)?
    var onClipboardWrite: ((String) -> Void)?
    var onClipboardRead: (() -> String?)?
    var encodeText: ((String) -> Data?)?
    var decodeText: ((Data) -> String?)?
    var mouseReportingPolicy: ((MouseReportingMode, Bool) -> Bool)?
    var onWindowResizeRequest: ((_ rows: Int, _ cols: Int) -> Void)?
    var onWindowPixelResizeRequest: ((_ width: Int, _ height: Int) -> Void)?
    var onClearScrollback: (() -> Void)?

    /// OSC string accumulator
    private var oscString: String = ""

    /// Maximum length for OSC strings in Swift layer (4KB is sufficient for all
    /// legitimate OSC commands: titles, color definitions, etc.)
    private static let maxOSCStringLength = 4096

    private var titleUpdateWindowStart: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var titleUpdateCount = 0

    enum MouseReportingMode {
        case none
        case x10        // Button press only
        case normal     // Button press and release
        case highlight  // Highlight tracking
        case buttonEvent // Button event tracking
        case anyEvent   // Any event tracking
    }

    enum MouseProtocol {
        case x10
        case sgr
    }

    var mouseProtocol: MouseProtocol = .x10
    var focusTrackingEnabled: Bool = false

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.grid = TerminalGrid(rows: rows, cols: cols)
        initTabStops()
    }

    // MARK: - Tab Stops

    private func initTabStops() {
        tabStopWords = Array(repeating: 0, count: Self.tabStopWordCount(for: max(cols, 0)))
        for col in stride(from: 0, to: cols, by: 8) {
            setTabStopBit(at: col, enabled: true)
        }
    }

    private func setTabStop(at column: Int) {
        guard column >= 0 else { return }
        ensureTabStopCapacity(for: column)
        setTabStopBit(at: column, enabled: true)
    }

    private func nextTabStop(after column: Int) -> Int? {
        guard column + 1 < cols else { return nil }
        for idx in (column + 1)..<cols where isTabStopSet(at: idx) {
            return idx
        }
        return nil
    }

    private static func tabStopWordCount(for columns: Int) -> Int {
        max(1, (max(columns, 0) + 63) / 64)
    }

    private static func tabStopBitLocation(for column: Int) -> (word: Int, bit: UInt64) {
        let word = column / 64
        let bit = UInt64(1) << UInt64(column % 64)
        return (word, bit)
    }

    private func ensureTabStopCapacity(for column: Int) {
        let requiredColumns = max(column + 1, cols)
        let requiredWordCount = Self.tabStopWordCount(for: requiredColumns)
        if requiredWordCount > tabStopWords.count {
            tabStopWords.append(contentsOf: repeatElement(0, count: requiredWordCount - tabStopWords.count))
        }
    }

    private func setTabStopBit(at column: Int, enabled: Bool) {
        guard column >= 0 else { return }
        ensureTabStopCapacity(for: column)
        let location = Self.tabStopBitLocation(for: column)
        if enabled {
            tabStopWords[location.word] |= location.bit
        } else {
            tabStopWords[location.word] &= ~location.bit
        }
    }

    private func isTabStopSet(at column: Int) -> Bool {
        guard column >= 0 else { return false }
        let location = Self.tabStopBitLocation(for: column)
        guard location.word < tabStopWords.count else { return false }
        return (tabStopWords[location.word] & location.bit) != 0
    }

    // MARK: - VT Parser Action Handling

    /// Process a VT parser action. Called from the parser callback.
    func handleAction(_ action: VtParserAction, codepoint: UInt32,
                      parser: UnsafePointer<VtParser>) {
        switch action {
        case VT_ACTION_PRINT:
            handlePrint(codepoint)

        case VT_ACTION_EXECUTE:
            handleExecute(codepoint)

        case VT_ACTION_CSI_DISPATCH:
            handleCSI(finalByte: codepoint, parser: parser)

        case VT_ACTION_ESC_DISPATCH:
            handleESC(finalByte: codepoint, parser: parser)

        case VT_ACTION_OSC_START:
            oscString = ""

        case VT_ACTION_OSC_PUT:
            if oscString.count < Self.maxOSCStringLength,
               let scalar = Unicode.Scalar(codepoint) {
                oscString.append(Character(scalar))
            }

        case VT_ACTION_OSC_END:
            handleOSC(oscString)

        default:
            break
        }
    }

    // MARK: - Print

    private func handlePrint(_ codepoint: UInt32) {
        let translatedCodepoint = translateCharacterSet(codepoint)
        let width = CharacterWidth.width(of: translatedCodepoint)
        guard width >= 0 else { return } // Non-printable

        // Handle pending wrap
        if cursor.pendingWrap {
            cursor.col = 0
            lineFeed()
            grid.setWrapped(cursor.row, true)
            cursor.pendingWrap = false
        }

        let charWidth = max(1, width)

        // Check if we need to wrap before printing
        if cursor.col + charWidth > cols {
            if cursor.autoWrapMode {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
            } else {
                cursor.col = cols - charWidth
            }
        }

        // Write the cell
        let cell = Cell(
            codepoint: translatedCodepoint,
            attributes: cursor.attributes,
            width: UInt8(charWidth),
            isWideContinuation: false
        )
        grid.setCell(cell, at: cursor.row, col: cursor.col)

        // For double-width characters, mark the continuation cell
        if charWidth == 2 && cursor.col + 1 < cols {
            let contCell = Cell(
                codepoint: 0,
                attributes: cursor.attributes,
                width: 0,
                isWideContinuation: true
            )
            grid.setCell(contCell, at: cursor.row, col: cursor.col + 1)
        }

        // Advance cursor
        cursor.col += charWidth
        if cursor.col >= cols {
            if cursor.autoWrapMode {
                cursor.pendingWrap = true
                cursor.col = cols - 1
            } else {
                cursor.col = cols - 1
            }
        }
    }

    // MARK: - C0 Controls

    private func handleExecute(_ cp: UInt32) {
        switch cp {
        case 0x07: // BEL
            onBell?()

        case 0x08: // BS (Backspace)
            if cursor.col > 0 {
                cursor.col -= 1
                cursor.pendingWrap = false
            }

        case 0x09: // HT (Horizontal Tab)
            let nextTab = nextTabStop(after: cursor.col) ?? (cols - 1)
            cursor.col = min(nextTab, cols - 1)
            cursor.pendingWrap = false

        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            lineFeed()

        case 0x0D: // CR
            cursor.col = 0
            cursor.pendingWrap = false

        case 0x0E: // SO (Shift Out) - G1 character set
            activeCharsetIsG1 = true

        case 0x0F: // SI (Shift In) - G0 character set
            activeCharsetIsG1 = false

        default:
            break
        }
    }

    // MARK: - Line Feed

    private func lineFeed() {
        if cursor.row == grid.scrollBottom {
            // At bottom of scroll region: scroll up
            // Save the line being scrolled out
            let scrolledRow = Array(grid.rowCells(grid.scrollTop))
            let isWrapped = grid.isWrapped(grid.scrollTop)
            onScrollOut?(scrolledRow, isWrapped)
            grid.scrollUp(count: 1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
        cursor.pendingWrap = false
    }

    // MARK: - CSI Sequences

    private func handleCSI(finalByte: UInt32, parser: UnsafePointer<VtParser>) {
        let hasPrivateMarker = parser.pointee.intermediate_count > 0 &&
            (parser.pointee.intermediates.0 == UInt8(ascii: "?") ||
             parser.pointee.intermediates.0 == UInt8(ascii: ">") ||
             parser.pointee.intermediates.0 == UInt8(ascii: "="))
        let privateMarker = hasPrivateMarker ? parser.pointee.intermediates.0 : 0

        switch finalByte {
        case 0x41: // CUU - Cursor Up
            let n = vt_parser_param(parser, 0, 1)
            cursor.row = max(grid.scrollTop, cursor.row - Int(n))
            cursor.pendingWrap = false

        case 0x42: // CUD - Cursor Down
            let n = vt_parser_param(parser, 0, 1)
            cursor.row = min(grid.scrollBottom, cursor.row + Int(n))
            cursor.pendingWrap = false

        case 0x43: // CUF - Cursor Forward
            let n = vt_parser_param(parser, 0, 1)
            cursor.col = min(cols - 1, cursor.col + Int(n))
            cursor.pendingWrap = false

        case 0x44: // CUB - Cursor Backward
            let n = vt_parser_param(parser, 0, 1)
            cursor.col = max(0, cursor.col - Int(n))
            cursor.pendingWrap = false

        case 0x45: // CNL - Cursor Next Line
            let n = vt_parser_param(parser, 0, 1)
            cursor.row = min(grid.scrollBottom, cursor.row + Int(n))
            cursor.col = 0
            cursor.pendingWrap = false

        case 0x46: // CPL - Cursor Previous Line
            let n = vt_parser_param(parser, 0, 1)
            cursor.row = max(grid.scrollTop, cursor.row - Int(n))
            cursor.col = 0
            cursor.pendingWrap = false

        case 0x47: // CHA - Cursor Character Absolute
            let n = vt_parser_param(parser, 0, 1)
            cursor.col = min(cols - 1, max(0, Int(n) - 1))
            cursor.pendingWrap = false

        case 0x48: // CUP - Cursor Position
            let row = vt_parser_param(parser, 0, 1)
            let col = vt_parser_param(parser, 1, 1)
            cursor.row = min(rows - 1, max(0, Int(row) - 1))
            cursor.col = min(cols - 1, max(0, Int(col) - 1))
            cursor.pendingWrap = false

        case 0x4A: // ED - Erase in Display
            handleEraseDisplay(param: vt_parser_param(parser, 0, 0))

        case 0x4B: // EL - Erase in Line
            handleEraseLine(param: vt_parser_param(parser, 0, 0))

        case 0x4C: // IL - Insert Lines
            let n = Int(vt_parser_param(parser, 0, 1))
            if cursor.row >= grid.scrollTop && cursor.row <= grid.scrollBottom {
                let savedTop = grid.scrollTop
                grid.scrollTop = cursor.row
                grid.scrollDown(count: n)
                grid.scrollTop = savedTop
            }

        case 0x4D: // DL - Delete Lines
            let n = Int(vt_parser_param(parser, 0, 1))
            if cursor.row >= grid.scrollTop && cursor.row <= grid.scrollBottom {
                let savedTop = grid.scrollTop
                grid.scrollTop = cursor.row
                grid.scrollUp(count: n)
                grid.scrollTop = savedTop
            }

        case 0x50: // DCH - Delete Characters
            let n = Int(vt_parser_param(parser, 0, 1))
            grid.deleteCells(row: cursor.row, col: cursor.col, count: n)

        case 0x53: // SU - Scroll Up
            let n = Int(vt_parser_param(parser, 0, 1))
            grid.scrollUp(count: n)

        case 0x54: // SD - Scroll Down
            let n = Int(vt_parser_param(parser, 0, 1))
            grid.scrollDown(count: n)

        case 0x58: // ECH - Erase Characters
            let n = Int(vt_parser_param(parser, 0, 1))
            grid.clearCells(row: cursor.row, fromCol: cursor.col,
                           toCol: cursor.col + n - 1)

        case 0x40: // ICH - Insert Characters
            let n = Int(vt_parser_param(parser, 0, 1))
            grid.insertBlanks(row: cursor.row, col: cursor.col, count: n)

        case 0x62: // REP - Repeat preceding character
            // Security: cap at screen area to prevent CPU DoS
            let screenArea = rows * cols
            let n = min(Int(vt_parser_param(parser, 0, 1)), screenArea)
            let prevCell = cursor.col > 0
                ? grid.cell(at: cursor.row, col: cursor.col - 1)
                : Cell.empty
            if prevCell.codepoint != 0 {
                for _ in 0..<n {
                    handlePrint(prevCell.codepoint)
                }
            }

        case 0x64: // VPA - Vertical Position Absolute
            let n = vt_parser_param(parser, 0, 1)
            cursor.row = min(rows - 1, max(0, Int(n) - 1))
            cursor.pendingWrap = false

        case 0x66: // HVP - Horizontal and Vertical Position (same as CUP)
            let row = vt_parser_param(parser, 0, 1)
            let col = vt_parser_param(parser, 1, 1)
            cursor.row = min(rows - 1, max(0, Int(row) - 1))
            cursor.col = min(cols - 1, max(0, Int(col) - 1))
            cursor.pendingWrap = false

        case 0x68: // SM - Set Mode
            handleSetMode(parser: parser, privateMarker: privateMarker, set: true)

        case 0x6C: // RM - Reset Mode
            handleSetMode(parser: parser, privateMarker: privateMarker, set: false)

        case 0x6D: // SGR - Select Graphic Rendition
            handleSGR(parser: parser)

        case 0x6E: // DSR - Device Status Report
            handleDSR(parser: parser)

        case 0x72: // DECSTBM - Set Top and Bottom Margins
            let top = Int(vt_parser_param(parser, 0, 1)) - 1
            let bottom = Int(vt_parser_param(parser, 1, Int32(rows))) - 1
            grid.scrollTop = max(0, min(top, rows - 1))
            grid.scrollBottom = max(grid.scrollTop, min(bottom, rows - 1))
            cursor.row = cursor.originMode ? grid.scrollTop : 0
            cursor.col = 0
            cursor.pendingWrap = false

        case 0x71: // DECSCUSR (Set Cursor Style) — CSI Ps SP q
            if parser.pointee.intermediate_count == 1 &&
               parser.pointee.intermediates.0 == 0x20 {
                let ps = Int(vt_parser_param(parser, 0, 0))
                switch ps {
                case 0, 1: cursor.shape = .block;     cursor.blinking = true
                case 2:    cursor.shape = .block;     cursor.blinking = false
                case 3:    cursor.shape = .underline;  cursor.blinking = true
                case 4:    cursor.shape = .underline;  cursor.blinking = false
                case 5:    cursor.shape = .bar;        cursor.blinking = true
                case 6:    cursor.shape = .bar;        cursor.blinking = false
                default:   break
                }
            }

        case 0x74: // Window manipulation
            handleWindowManipulation(parser: parser)

        default:
            break // Unknown CSI: silently discard
        }
    }

    private func handleWindowManipulation(parser: UnsafePointer<VtParser>) {
        let operation = vt_parser_param(parser, 0, 0)
        switch operation {
        case 8:
            let targetRows = max(1, Int(vt_parser_param(parser, 1, Int32(rows))))
            let targetCols = max(1, Int(vt_parser_param(parser, 2, Int32(cols))))
            onWindowResizeRequest?(targetRows, targetCols)
        case 4:
            let targetHeight = max(1, Int(vt_parser_param(parser, 1, 0)))
            let targetWidth = max(1, Int(vt_parser_param(parser, 2, 0)))
            guard targetWidth > 0, targetHeight > 0 else { return }
            onWindowPixelResizeRequest?(targetWidth, targetHeight)
        default:
            break
        }
    }

    // MARK: - Erase

    private func handleEraseDisplay(param: Int32) {
        switch param {
        case 0: // Erase from cursor to end of display
            grid.clearCells(row: cursor.row, fromCol: cursor.col, toCol: cols - 1)
            for row in (cursor.row + 1)..<rows {
                grid.clearRow(row)
            }
        case 1: // Erase from start to cursor
            for row in 0..<cursor.row {
                grid.clearRow(row)
            }
            grid.clearCells(row: cursor.row, fromCol: 0, toCol: cursor.col)
        case 2: // Erase entire display
            grid.clearAll()
        case 3: // Erase scrollback (xterm extension)
            onClearScrollback?()
            grid.clearAll()
        default:
            break
        }
    }

    private func handleEraseLine(param: Int32) {
        switch param {
        case 0: // Erase from cursor to end of line
            grid.clearCells(row: cursor.row, fromCol: cursor.col, toCol: cols - 1)
        case 1: // Erase from start to cursor
            grid.clearCells(row: cursor.row, fromCol: 0, toCol: cursor.col)
        case 2: // Erase entire line
            grid.clearRow(cursor.row)
        default:
            break
        }
    }

    // MARK: - Mode Set/Reset

    private func handleSetMode(parser: UnsafePointer<VtParser>,
                                privateMarker: UInt8, set: Bool) {
        let paramCount = max(1, parser.pointee.param_count)

        for i in 0..<paramCount {
            let mode = vt_parser_param(parser, UInt32(i), 0)

            if privateMarker == UInt8(ascii: "?") {
                // DEC private modes
                switch mode {
                case 1: // DECCKM - Application Cursor Keys
                    applicationCursorKeys = set
                case 6: // DECOM - Origin Mode
                    cursor.originMode = set
                    cursor.row = set ? grid.scrollTop : 0
                    cursor.col = 0
                case 7: // DECAWM - Auto-Wrap Mode
                    cursor.autoWrapMode = set
                case 12: // Cursor blink (att610)
                    break // We always use smooth blink
                case 25: // DECTCEM - Text Cursor Enable Mode
                    cursor.visible = set
                case 47, 1047: // Alternate Screen Buffer
                    switchScreen(alternate: set)
                case 1000: // X10 mouse reporting
                    setMouseReporting(set ? .x10 : .none)
                case 1002: // Button event mouse reporting
                    setMouseReporting(set ? .buttonEvent : .none)
                case 1003: // Any event mouse reporting
                    setMouseReporting(set ? .anyEvent : .none)
                case 1004: // Focus tracking
                    focusTrackingEnabled = set
                case 1006: // SGR mouse mode
                    mouseProtocol = set ? .sgr : .x10
                case 1049: // Alternate Screen + save cursor
                    if set {
                        cursor.save()
                        switchScreen(alternate: true)
                        grid.clearAll()
                    } else {
                        switchScreen(alternate: false)
                        cursor.restore()
                    }
                case 2004: // Bracketed paste mode
                    bracketedPasteMode = set
                default:
                    break
                }
            }
            // Standard ANSI modes are rarely used; ignore for now
        }
    }

    // MARK: - Alternate Screen

    private func switchScreen(alternate: Bool) {
        guard alternate != isAlternateScreen else { return }

        if alternate {
            alternateGrid = grid
            grid = TerminalGrid(rows: rows, cols: cols)
        } else {
            if let saved = alternateGrid {
                grid = saved
                alternateGrid = nil
            }
        }

        isAlternateScreen = alternate
        if !alternate {
            mouseReporting = .none
        }
    }

    private func setMouseReporting(_ mode: MouseReportingMode) {
        guard mode != .none else {
            mouseReporting = .none
            return
        }
        if mouseReportingPolicy?(mode, isAlternateScreen) ?? true {
            mouseReporting = mode
        } else {
            mouseReporting = .none
        }
    }

    // MARK: - SGR (Select Graphic Rendition)

    private func handleSGR(parser: UnsafePointer<VtParser>) {
        let paramCount = parser.pointee.param_count == 0 ? 1 : parser.pointee.param_count
        var i: UInt32 = 0

        while i < paramCount {
            let param = vt_parser_param(parser, i, 0)
            switch param {
            case 0: // Reset
                cursor.attributes = .default
            case 1:
                cursor.attributes.bold = true
            case 2:
                cursor.attributes.dim = true
            case 3:
                cursor.attributes.italic = true
            case 4:
                cursor.attributes.underline = true
            case 5, 6:
                cursor.attributes.blink = true
            case 7:
                cursor.attributes.inverse = true
            case 8:
                cursor.attributes.hidden = true
            case 9:
                cursor.attributes.strikethrough = true
            case 21:
                cursor.attributes.bold = false
            case 22:
                cursor.attributes.bold = false
                cursor.attributes.dim = false
            case 23:
                cursor.attributes.italic = false
            case 24:
                cursor.attributes.underline = false
            case 25:
                cursor.attributes.blink = false
            case 27:
                cursor.attributes.inverse = false
            case 28:
                cursor.attributes.hidden = false
            case 29:
                cursor.attributes.strikethrough = false
            case 30...37: // Standard foreground colors
                cursor.attributes.foreground = .indexed(UInt8(param - 30))
            case 38: // Extended foreground color
                i = parseSGRColor(parser: parser, startIndex: i, isForeground: true)
            case 39: // Default foreground
                cursor.attributes.foreground = .default
            case 40...47: // Standard background colors
                cursor.attributes.background = .indexed(UInt8(param - 40))
            case 48: // Extended background color
                i = parseSGRColor(parser: parser, startIndex: i, isForeground: false)
            case 49: // Default background
                cursor.attributes.background = .default
            case 90...97: // Bright foreground colors
                cursor.attributes.foreground = .indexed(UInt8(param - 90 + 8))
            case 100...107: // Bright background colors
                cursor.attributes.background = .indexed(UInt8(param - 100 + 8))
            default:
                break
            }
            i += 1
        }
    }

    /// Parse extended SGR color (38;5;N or 38;2;R;G;B)
    private func parseSGRColor(parser: UnsafePointer<VtParser>,
                                startIndex: UInt32,
                                isForeground: Bool) -> UInt32 {
        var i = startIndex + 1
        let mode = vt_parser_param(parser, i, 0)

        switch mode {
        case 5: // 256-color: 38;5;N
            i += 1
            let colorIdx = UInt8(clamping: vt_parser_param(parser, i, 0))
            let color = TerminalColor.indexed(colorIdx)
            if isForeground {
                cursor.attributes.foreground = color
            } else {
                cursor.attributes.background = color
            }

        case 2: // TrueColor: 38;2;R;G;B
            let r = UInt8(clamping: vt_parser_param(parser, i + 1, 0))
            let g = UInt8(clamping: vt_parser_param(parser, i + 2, 0))
            let b = UInt8(clamping: vt_parser_param(parser, i + 3, 0))
            let color = TerminalColor.rgb(r, g, b)
            if isForeground {
                cursor.attributes.foreground = color
            } else {
                cursor.attributes.background = color
            }
            i += 3

        default:
            break
        }

        return i
    }

    // MARK: - DSR (Device Status Report)

    /// Response callback: writes response bytes to PTY
    var onResponse: ((String) -> Void)?

    private func handleDSR(parser: UnsafePointer<VtParser>) {
        let param = vt_parser_param(parser, 0, 0)
        switch param {
        case 5: // Status report
            // Response: OK
            sendResponse("\u{1B}[0n")
        case 6: // Cursor position report
            sendResponse("\u{1B}[\(cursor.row + 1);\(cursor.col + 1)R")
        default:
            break
        }
    }

    private func sendResponse(_ response: String) {
        // Security: sanitize response - strip any control characters from
        // dynamic content. For DSR, the row/col are integers so this is safe.
        onResponse?(response)
    }

    // MARK: - ESC Sequences

    private func handleESC(finalByte: UInt32, parser: UnsafePointer<VtParser>) {
        let p = parser.pointee

        // Check for intermediate characters
        if p.intermediate_count > 0 {
            let intermediate = p.intermediates.0

            // Character set designation
            if intermediate == UInt8(ascii: "(") ||
               intermediate == UInt8(ascii: ")") ||
               intermediate == UInt8(ascii: "*") ||
               intermediate == UInt8(ascii: "+") {
                designateCharacterSet(intermediate: intermediate, finalByte: finalByte)
                return
            }

            if intermediate == UInt8(ascii: "#") {
                // DEC screen alignment test etc.
                return
            }
        }

        switch finalByte {
        case 0x37: // DECSC - Save Cursor
            cursor.save()

        case 0x38: // DECRC - Restore Cursor
            cursor.restore()

        case 0x44: // IND - Index (move cursor down, scroll if at bottom)
            lineFeed()

        case 0x45: // NEL - Next Line
            cursor.col = 0
            lineFeed()

        case 0x48: // HTS - Horizontal Tab Set
            setTabStop(at: cursor.col)

        case 0x4D: // RI - Reverse Index (move cursor up, scroll if at top)
            if cursor.row == grid.scrollTop {
                grid.scrollDown(count: 1)
            } else if cursor.row > 0 {
                cursor.row -= 1
            }

        case 0x63: // RIS - Reset to Initial State
            reset()

        default:
            break
        }
    }

    // MARK: - OSC Sequences

    /// Sanitize a string for use as a terminal title.
    /// Strips control characters, C1 codes, bidirectional overrides,
    /// and limits length to prevent abuse.
    private static func sanitizeTitle(_ raw: String) -> String {
        let maxTitleLength = 256
        var result = ""
        result.reserveCapacity(min(raw.count, maxTitleLength))

        for scalar in raw.unicodeScalars {
            let v = scalar.value
            // Reject C0 control (0x00-0x1F), DEL (0x7F), C1 control (0x80-0x9F)
            if v <= 0x1F || v == 0x7F || (v >= 0x80 && v <= 0x9F) { continue }
            // Reject Unicode bidirectional override characters
            if v == 0x202A || v == 0x202B || v == 0x202C || v == 0x202D || v == 0x202E { continue }
            // Reject additional bidi isolate characters (Unicode 6.3+)
            if v == 0x2066 || v == 0x2067 || v == 0x2068 || v == 0x2069 { continue }
            result.append(Character(scalar))
            if result.count >= maxTitleLength { break }
        }
        return result
    }

    private func handleOSC(_ str: String) {
        // Parse OSC command: "N;text" where N is a number
        guard let separatorIndex = str.firstIndex(of: ";") else { return }

        let commandStr = String(str[str.startIndex..<separatorIndex])
        let text = String(str[str.index(after: separatorIndex)...])

        guard let command = Int(commandStr) else { return }

        switch command {
        case 0: // Set icon name and window title
            applyTitleUpdate(text)

        case 1: // Set icon name
            break

        case 2: // Set window title
            applyTitleUpdate(text)

        case 52: // Clipboard access (OSC 52)
            handleOSC52(text)

        default:
            break
        }
    }

    private func applyTitleUpdate(_ rawTitle: String) {
        guard consumeTitleUpdateBudget() else { return }
        let safe = Self.sanitizeTitle(rawTitle)
        title = safe
        onTitleChange?(safe)
    }

    private func consumeTitleUpdateBudget(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if now - titleUpdateWindowStart >= TitleUpdateRateLimit.interval {
            titleUpdateWindowStart = now
            titleUpdateCount = 0
        }

        guard titleUpdateCount < TitleUpdateRateLimit.maxUpdatesPerInterval else {
            return false
        }

        titleUpdateCount += 1
        return true
    }

    private func handleOSC52(_ payload: String) {
        let components = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else { return }
        let target = String(components[0])
        let data = String(components[1])

        if data == "?" {
            guard let clipboardText = onClipboardRead?() else { return }
            guard let encodedData = encodeText?(clipboardText) ?? clipboardText.data(using: .utf8) else {
                return
            }
            let encoded = encodedData.base64EncodedString()
            sendResponse("\u{1B}]52;\(target);\(encoded)\u{07}")
            return
        }

        guard let decoded = Data(base64Encoded: data),
              let string = decodeText?(decoded) ?? String(data: decoded, encoding: .utf8) else {
            return
        }
        onClipboardWrite?(string)
    }

    // MARK: - Reset

    func reset() {
        grid.clearAll()
        cursor = CursorState()
        grid.scrollTop = 0
        grid.scrollBottom = rows - 1
        bracketedPasteMode = false
        applicationCursorKeys = false
        mouseReporting = .none
        mouseProtocol = .x10
        focusTrackingEnabled = false
        isAlternateScreen = false
        alternateGrid = nil
        g0Charset = .ascii
        g1Charset = .ascii
        activeCharsetIsG1 = false
        initTabStops()
    }

    func notifyFocusChanged(_ isFocused: Bool) {
        guard focusTrackingEnabled else { return }
        sendResponse(isFocused ? "\u{1B}[I" : "\u{1B}[O")
    }

    private func designateCharacterSet(intermediate: UInt8, finalByte: UInt32) {
        let charset: DesignatedCharacterSet
        switch finalByte {
        case 0x30: // "0" = DEC Special Graphics
            charset = .decSpecialGraphics
        case 0x42: // "B" = US ASCII
            charset = .ascii
        default:
            return
        }

        switch intermediate {
        case UInt8(ascii: "("):
            g0Charset = charset
        case UInt8(ascii: ")"):
            g1Charset = charset
        default:
            return
        }
    }

    private func translateCharacterSet(_ codepoint: UInt32) -> UInt32 {
        let charset = activeCharsetIsG1 ? g1Charset : g0Charset
        guard charset == .decSpecialGraphics else { return codepoint }

        switch codepoint {
        case 0x5F: return 0x00A0 // no-break space
        case 0x60: return 0x25C6 // black diamond
        case 0x61: return 0x2592 // medium shade
        case 0x62: return 0x2409 // symbol for horizontal tab
        case 0x63: return 0x240C // symbol for form feed
        case 0x64: return 0x240D // symbol for carriage return
        case 0x65: return 0x240A // symbol for line feed
        case 0x66: return 0x00B0 // degree sign
        case 0x67: return 0x00B1 // plus-minus sign
        case 0x68: return 0x2424 // symbol for newline
        case 0x69: return 0x240B // symbol for vertical tab
        case 0x6A: return 0x2518 // box drawings light up and left
        case 0x6B: return 0x2510 // box drawings light down and left
        case 0x6C: return 0x250C // box drawings light down and right
        case 0x6D: return 0x2514 // box drawings light up and right
        case 0x6E: return 0x253C // box drawings light vertical and horizontal
        case 0x6F: return 0x23BA // horizontal scan line 1
        case 0x70: return 0x23BB // horizontal scan line 3
        case 0x71: return 0x2500 // box drawings light horizontal
        case 0x72: return 0x23BC // horizontal scan line 7
        case 0x73: return 0x23BD // horizontal scan line 9
        case 0x74: return 0x251C // box drawings light vertical and right
        case 0x75: return 0x2524 // box drawings light vertical and left
        case 0x76: return 0x2534 // box drawings light up and horizontal
        case 0x77: return 0x252C // box drawings light down and horizontal
        case 0x78: return 0x2502 // box drawings light vertical
        case 0x79: return 0x2264 // less-than or equal to
        case 0x7A: return 0x2265 // greater-than or equal to
        case 0x7B: return 0x03C0 // pi
        case 0x7C: return 0x2260 // not equal to
        case 0x7D: return 0x00A3 // pound sign
        case 0x7E: return 0x00B7 // middle dot
        default:
            return codepoint
        }
    }

    // MARK: - Resize

    func resize(newRows: Int, newCols: Int) {
        let result = grid.resize(newRows: newRows, newCols: newCols,
                                  cursorRow: cursor.row, cursorCol: cursor.col)

        // Save trimmed rows to scrollback before they are lost
        for trimmed in result.trimmedRows {
            onScrollOut?(trimmed.cells, trimmed.isWrapped)
        }

        // Alternate grid doesn't need cursor-aware re-wrap
        _ = alternateGrid?.resize(newRows: newRows, newCols: newCols,
                                   cursorRow: 0, cursorCol: 0)
        rows = newRows
        cols = newCols
        cursor.row = result.cursorRow
        cursor.col = result.cursorCol
        cursor.pendingWrap = false
        initTabStops()
    }


}

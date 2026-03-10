import Foundation
import PtermCore

/// Core terminal emulation model.
///
/// Owns the character grid and cursor state. Processes VT parser actions
/// to update the terminal display. This is the bridge between the C VT parser
/// and the Swift rendering layer.
final class TerminalModel {
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

    /// Tab stops
    private var tabStops: Set<Int> = []

    /// Callback when a line scrolls off the top of the screen (for scrollback)
    var onScrollOut: ((_ cells: [Cell], _ isWrapped: Bool) -> Void)?

    /// Callback when title changes
    var onTitleChange: ((String) -> Void)?

    /// Callback when bell is triggered
    var onBell: (() -> Void)?

    /// OSC string accumulator
    private var oscString: String = ""

    /// Maximum length for OSC strings in Swift layer (4KB is sufficient for all
    /// legitimate OSC commands: titles, color definitions, etc.)
    private static let maxOSCStringLength = 4096

    enum MouseReportingMode {
        case none
        case x10        // Button press only
        case normal     // Button press and release
        case highlight  // Highlight tracking
        case buttonEvent // Button event tracking
        case anyEvent   // Any event tracking
    }

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.grid = TerminalGrid(rows: rows, cols: cols)
        initTabStops()
    }

    // MARK: - Tab Stops

    private func initTabStops() {
        tabStops.removeAll()
        for col in stride(from: 0, to: cols, by: 8) {
            tabStops.insert(col)
        }
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
        let width = CharacterWidth.width(of: codepoint)
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
            codepoint: codepoint,
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
            let nextTab = tabStops.sorted().first(where: { $0 > cursor.col }) ?? (cols - 1)
            cursor.col = min(nextTab, cols - 1)
            cursor.pendingWrap = false

        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            lineFeed()

        case 0x0D: // CR
            cursor.col = 0
            cursor.pendingWrap = false

        case 0x0E: // SO (Shift Out) - G1 character set
            break // TODO: character set switching

        case 0x0F: // SI (Shift In) - G0 character set
            break // TODO: character set switching

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

        default:
            break // Unknown CSI: silently discard
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
            // TODO: clear ring buffer
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
                    mouseReporting = set ? .x10 : .none
                case 1002: // Button event mouse reporting
                    mouseReporting = set ? .buttonEvent : .none
                case 1003: // Any event mouse reporting
                    mouseReporting = set ? .anyEvent : .none
                case 1004: // Focus tracking
                    break // TODO
                case 1006: // SGR mouse mode
                    break // TODO: SGR mouse encoding
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
    var onResponse: ((Data) -> Void)?

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
        guard let data = response.data(using: .utf8) else { return }
        onResponse?(data)
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
                // TODO: G0/G1/G2/G3 character set designation
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
            tabStops.insert(cursor.col)

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
            let safe = Self.sanitizeTitle(text)
            title = safe
            onTitleChange?(safe)

        case 1: // Set icon name
            break

        case 2: // Set window title
            let safe = Self.sanitizeTitle(text)
            title = safe
            onTitleChange?(safe)

        case 52: // Clipboard access (OSC 52)
            // Handled by security layer - not processed here
            // Read: denied by default. Write: allowed by default.
            break

        default:
            break
        }
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
        isAlternateScreen = false
        alternateGrid = nil
        initTabStops()
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

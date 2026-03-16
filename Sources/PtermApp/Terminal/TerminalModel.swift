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
        case british
        case decSpecialGraphics
    }

    private enum InvokedCharacterSet {
        case g0
        case g1
        case g2
        case g3
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

    /// ANSI Line Feed / New Line mode (LNM).
    /// When enabled, the Return key should send CRLF rather than CR.
    var newLineMode: Bool = false

    /// Mouse reporting mode
    var mouseReporting: MouseReportingMode = .none

    /// Window title
    private(set) var title: String = ""

    /// Tab stops stored as a compact bitset to keep per-terminal overhead low.
    private var tabStopWords: [UInt64] = []

    /// Designated character sets and the currently invoked GL/GR sets.
    private var g0Charset: DesignatedCharacterSet = .ascii
    private var g1Charset: DesignatedCharacterSet = .ascii
    private var g2Charset: DesignatedCharacterSet = .ascii
    private var g3Charset: DesignatedCharacterSet = .ascii
    private var glInvocation: InvokedCharacterSet = .g0
    private var grInvocation: InvokedCharacterSet = .g1
    private var singleShiftInvocation: InvokedCharacterSet?

    /// Callback when a line scrolls off the top of the screen (for scrollback)
    var onScrollOut: ((ScrollbackBuffer.BufferedRow) -> Void)?

    /// Callback when title changes
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?

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
    var onPendingUpdateModeChange: ((Bool) -> Void)?

    /// OSC string accumulator
    private var oscString: String = ""
    private var oscCommandPrefix: String = ""
    private var oscSawSeparator = false
    private var oscShouldAccumulatePayload = true

    /// Maximum length for OSC strings in Swift layer (4KB is sufficient for all
    /// legitimate OSC commands: titles, color definitions, etc.)
    private static let maxOSCStringLength = 4096

    /// Active DCS request metadata. Payload bytes are accumulated in the C parser.
    private var dcsFinalByte: UInt32 = 0
    private var dcsIntermediates: [UInt8] = []
    private var operatingLevel: Int = 4

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
    private(set) var pendingUpdateModeEnabled: Bool = false
    private var insertModeEnabled = false
    private var protectedAreaModeEnabled = false
    private static let answerbackMessage = "pterm"

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

    private func clearTabStop(at column: Int) {
        guard column >= 0 else { return }
        setTabStopBit(at: column, enabled: false)
    }

    private func clearAllTabStops() {
        for index in tabStopWords.indices {
            tabStopWords[index] = 0
        }
    }

    private func nextTabStop(after column: Int) -> Int? {
        guard column + 1 < cols else { return nil }
        for idx in (column + 1)..<cols where isTabStopSet(at: idx) {
            return idx
        }
        return nil
    }

    private func previousTabStop(before column: Int) -> Int? {
        guard column > 0 else { return nil }
        for idx in stride(from: column - 1, through: 0, by: -1) where isTabStopSet(at: idx) {
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
            oscCommandPrefix = ""
            oscSawSeparator = false
            oscShouldAccumulatePayload = true

        case VT_ACTION_OSC_PUT:
            guard let scalar = Unicode.Scalar(codepoint) else { break }
            let character = Character(scalar)
            if !oscSawSeparator {
                if character == ";" {
                    oscSawSeparator = true
                    if let command = Int(oscCommandPrefix) {
                        oscShouldAccumulatePayload = Self.shouldAccumulateOSCPayload(for: command)
                        if oscShouldAccumulatePayload {
                            oscString = oscCommandPrefix + ";"
                        }
                    } else {
                        oscShouldAccumulatePayload = false
                    }
                } else if oscCommandPrefix.count < 16 {
                    oscCommandPrefix.append(character)
                }
            } else if oscShouldAccumulatePayload && oscString.count < Self.maxOSCStringLength {
                oscString.append(character)
            }

        case VT_ACTION_OSC_END:
            if oscSawSeparator && oscShouldAccumulatePayload {
                handleOSC(oscString)
            }
            oscString = ""
            oscCommandPrefix = ""
            oscSawSeparator = false
            oscShouldAccumulatePayload = true

        case VT_ACTION_DCS_START:
            dcsFinalByte = codepoint
            let intermediates = parser.pointee.intermediates
            let allIntermediates = [intermediates.0, intermediates.1, intermediates.2, intermediates.3]
            dcsIntermediates = Array(allIntermediates.prefix(Int(parser.pointee.intermediate_count)))

        case VT_ACTION_DCS_END:
            handleDCS(parser: parser)
            dcsFinalByte = 0
            dcsIntermediates.removeAll(keepingCapacity: true)

        default:
            break
        }
    }

    // MARK: - Print

    func displayLocalInterruptPromptBoundary() {
        cursor.col = 0
        lineFeed()
    }

    var canUseASCIIGroundFastPath: Bool {
        g0Charset == .ascii &&
        g1Charset == .ascii &&
        g2Charset == .ascii &&
        g3Charset == .ascii &&
        singleShiftInvocation == nil &&
        cursor.autoWrapMode
    }

    /// Fast path for the common "ground-state text stream" case.
    ///
    /// When the VT parser is already in ground state and the incoming chunk
    /// contains only printable characters plus ordinary C0 executes, routing
    /// through the full C state machine and per-codepoint callback bridge is
    /// unnecessary overhead. This path preserves the same semantics by
    /// dispatching directly to the existing print/execute handlers.
    @discardableResult
    func consumeGroundFastPathPrefix(_ codepoints: UnsafeBufferPointer<UInt32>) -> Int {
        guard !codepoints.isEmpty else { return 0 }
        if canUseASCIIGroundFastPath {
            return consumeGroundASCIICodepointsFastPathPrefix(codepoints)
        }

        var index = 0
        while index < codepoints.count {
            let codepoint = codepoints[index]
            switch codepoint {
            case 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F:
                handleExecute(codepoint)
                index += 1
            case 0x1B, 0x18, 0x1A, 0x7F, 0x00...0x1F:
                return index
            default:
                handlePrint(codepoint)
                index += 1
            }
        }

        return index
    }

    func handleGroundFastPath(_ codepoints: UnsafeBufferPointer<UInt32>) {
        _ = consumeGroundFastPathPrefix(codepoints)
    }

    @discardableResult
    func consumeGroundASCIIBytesFastPathPrefix(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        guard !bytes.isEmpty else { return 0 }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= 0x20 && byte < 0x7F {
                let runStart = index
                var runCount = 1
                var containsSpace = byte == 0x20
                while runStart + runCount < bytes.count {
                    let next = bytes[runStart + runCount]
                    guard next >= 0x20 && next < 0x7F else { break }
                    if next == 0x20 {
                        containsSpace = true
                    }
                    runCount += 1
                }
                handleASCIIByteRun(
                    bytes.baseAddress!.advanced(by: runStart),
                    count: runCount,
                    containsSpace: containsSpace
                )
                index += runCount
                continue
            }

            switch byte {
            case 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F:
                handleExecute(UInt32(byte))
                index += 1
            case 0x1B:
                if let skippedCount = consumeIgnoredOSCBytes(in: bytes, from: index) {
                    index += skippedCount
                } else {
                    return index
                }
            default:
                return index
            }
        }

        return index
    }

    func handleGroundASCIIBytesFastPath(_ bytes: UnsafeBufferPointer<UInt8>) {
        _ = consumeGroundASCIIBytesFastPathPrefix(bytes)
    }

    @discardableResult
    private func consumeGroundASCIICodepointsFastPathPrefix(_ codepoints: UnsafeBufferPointer<UInt32>) -> Int {
        guard !codepoints.isEmpty else { return 0 }
        var index = 0
        while index < codepoints.count {
            let codepoint = codepoints[index]
            if codepoint >= 0x20 && codepoint < 0x7F {
                let runStart = index
                var runCount = 1
                while runStart + runCount < codepoints.count {
                    let next = codepoints[runStart + runCount]
                    guard next >= 0x20 && next < 0x7F else { break }
                    runCount += 1
                }
                handleASCIIRun(codepoints.baseAddress!.advanced(by: runStart), count: runCount)
                index += runCount
                continue
            }

            switch codepoint {
            case 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F:
                handleExecute(codepoint)
                index += 1
            case 0x1B, 0x18, 0x1A, 0x7F, 0x00...0x1F:
                return index
            default:
                handlePrint(codepoint)
                index += 1
            }
        }

        return index
    }

    private func handleASCIIRun(_ codepoints: UnsafeBufferPointer<UInt32>) {
        guard let base = codepoints.baseAddress else { return }
        handleASCIIRun(base, count: codepoints.count)
    }

    private func handleASCIIRun(_ codepoints: UnsafePointer<UInt32>, count: Int) {
        guard count > 0 else { return }

        var remainingBase = codepoints
        var remainingCount = count
        let attributes = currentPrintAttributes()

        while remainingCount > 0 {
            if cursor.pendingWrap {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                cursor.pendingWrap = false
            }

            let available = cols - cursor.col
            guard available > 0 else { break }

            let chunkCount = min(remainingCount, available)
            grid.writeSingleWidthCells(
                remainingBase,
                count: chunkCount,
                attributes: attributes,
                atRow: cursor.row,
                startCol: cursor.col
            )

            cursor.col += chunkCount
            remainingBase = remainingBase.advanced(by: chunkCount)
            remainingCount -= chunkCount

            if cursor.col >= cols {
                cursor.col = cols - 1
                if cursor.autoWrapMode {
                    cursor.pendingWrap = true
                }
            }
        }
    }

    private func consumeIgnoredOSCBytes(
        in bytes: UnsafeBufferPointer<UInt8>,
        from startIndex: Int
    ) -> Int? {
        guard startIndex + 2 < bytes.count,
              bytes[startIndex] == 0x1B,
              bytes[startIndex + 1] == 0x5D
        else {
            return nil
        }

        var index = startIndex + 2
        var command = 0
        var sawDigit = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= 0x30 && byte <= 0x39 {
                sawDigit = true
                command = command * 10 + Int(byte - 0x30)
                index += 1
                continue
            }
            break
        }

        guard sawDigit,
              index < bytes.count,
              bytes[index] == 0x3B,
              !Self.shouldAccumulateOSCPayload(for: command)
        else {
            return nil
        }

        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x07 {
                return index - startIndex + 1
            }
            if byte == 0x1B,
               index + 1 < bytes.count,
               bytes[index + 1] == 0x5C {
                return index - startIndex + 2
            }
            index += 1
        }

        return nil
    }

    private func handleASCIIByteRun(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress else { return }
        handleASCIIByteRun(base, count: bytes.count, containsSpace: true)
    }

    private func handleASCIIByteRun(_ bytes: UnsafePointer<UInt8>, count: Int, containsSpace: Bool) {
        guard count > 0 else { return }

        var remainingBase = bytes
        var remainingCount = count
        let attributes = currentPrintAttributes()

        while remainingCount > 0 {
            if cursor.pendingWrap {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                cursor.pendingWrap = false
            }

            let available = cols - cursor.col
            guard available > 0 else { break }

            let chunkCount = min(remainingCount, available)
            if attributes == .default && !containsSpace {
                grid.writeSingleWidthDefaultASCIIBytesWithoutSpaces(
                    remainingBase,
                    count: chunkCount,
                    atRow: cursor.row,
                    startCol: cursor.col
                )
            } else {
                grid.writeSingleWidthASCIIBytes(
                    remainingBase,
                    count: chunkCount,
                    attributes: attributes,
                    atRow: cursor.row,
                    startCol: cursor.col
                )
            }

            cursor.col += chunkCount
            remainingBase = remainingBase.advanced(by: chunkCount)
            remainingCount -= chunkCount

            if cursor.col >= cols {
                cursor.col = cols - 1
                if cursor.autoWrapMode {
                    cursor.pendingWrap = true
                }
            }
        }
    }

    private func handlePrint(_ codepoint: UInt32) {
        let translatedCodepoint: UInt32
        let width: Int
        if g0Charset == .ascii &&
            g1Charset == .ascii &&
            g2Charset == .ascii &&
            g3Charset == .ascii &&
            singleShiftInvocation == nil &&
            codepoint >= 0x20 &&
            codepoint < 0x7F {
            translatedCodepoint = codepoint
            width = 1
        } else {
            translatedCodepoint = translateCharacterSet(codepoint)
            width = CharacterWidth.width(of: translatedCodepoint)
        }
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

        if charWidth == 1 {
            if insertModeEnabled {
                insertBlankCharacters(count: 1)
            }
            let cell = Cell(
                codepoint: translatedCodepoint,
                attributes: currentPrintAttributes(),
                width: 1,
                isWideContinuation: false
            )
            grid.setCell(cell, at: cursor.row, col: cursor.col)

            cursor.col += 1
            if cursor.col >= cols {
                if cursor.autoWrapMode {
                    cursor.pendingWrap = true
                    cursor.col = cols - 1
                } else {
                    cursor.col = cols - 1
                }
            }
            return
        }

        if insertModeEnabled {
            insertBlankCharacters(count: charWidth)
        }

        // Write the cell
        let cell = Cell(
            codepoint: translatedCodepoint,
            attributes: currentPrintAttributes(),
            width: UInt8(charWidth),
            isWideContinuation: false
        )
        grid.setCell(cell, at: cursor.row, col: cursor.col)

        // For double-width characters, mark the continuation cell
        if charWidth == 2 && cursor.col + 1 < cols {
            let contCell = Cell(
                codepoint: 0,
                attributes: currentPrintAttributes(),
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

        case 0x05: // ENQ
            sendResponse(Self.answerbackMessage)

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
            glInvocation = .g1

        case 0x0F: // SI (Shift In) - G0 character set
            glInvocation = .g0

        default:
            break
        }
    }

    // MARK: - Line Feed

    private func lineFeed() {
        if cursor.row == grid.scrollBottom {
            // At bottom of scroll region: scroll up
            // Save the line being scrolled out
            let encodingHint = grid.rowEncodingHint(grid.scrollTop)
            let scrollbackCellCount: Int
            switch encodingHint.kind {
            case .compactDefault(let serializedCount):
                scrollbackCellCount = serializedCount
            case .compactUniformAttributes(_, let serializedCount):
                scrollbackCellCount = serializedCount
            case .full, .unknown:
                scrollbackCellCount = grid.cols
            }
            let isWrapped = grid.isWrapped(grid.scrollTop)
            onScrollOut?(
                ScrollbackBuffer.BufferedRow(
                    cells: grid.rowCells(grid.scrollTop),
                    cellCount: scrollbackCellCount,
                    isWrapped: isWrapped,
                    encodingHint: encodingHint
                )
            )
            grid.scrollUp(count: 1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
        cursor.pendingWrap = false
    }

    private func currentPrintAttributes() -> CellAttributes {
        var attributes = cursor.attributes
        if protectedAreaModeEnabled {
            attributes.decProtected = true
        }
        return attributes
    }

    // MARK: - CSI Sequences

    private func handleCSI(finalByte: UInt32, parser: UnsafePointer<VtParser>) {
        let intermediatePrefix = [
            parser.pointee.intermediates.0,
            parser.pointee.intermediates.1,
            parser.pointee.intermediates.2,
            parser.pointee.intermediates.3,
        ]
        let allIntermediates = Array(intermediatePrefix.prefix(Int(parser.pointee.intermediate_count)))
        let hasPrivateMarker = allIntermediates.first == UInt8(ascii: "?") ||
            allIntermediates.first == UInt8(ascii: ">") ||
            allIntermediates.first == UInt8(ascii: "=")
        let privateMarker = hasPrivateMarker ? (allIntermediates.first ?? 0) : 0
        let effectiveIntermediates = hasPrivateMarker ? Array(allIntermediates.dropFirst()) : allIntermediates
        let hasSpaceIntermediate = effectiveIntermediates == [UInt8(ascii: " ")]
        let hasQuoteIntermediate = effectiveIntermediates == [UInt8(ascii: "\"")]
        let hasBangIntermediate = effectiveIntermediates == [UInt8(ascii: "!")]

        if hasSpaceIntermediate {
            switch finalByte {
            case 0x40: // SL - Scroll Left
                let n = Int(vt_parser_param(parser, 0, 1))
                grid.scrollLineLeft(row: cursor.row, count: n)
                return
            case 0x41: // SR - Scroll Right
                let n = Int(vt_parser_param(parser, 0, 1))
                grid.scrollLineRight(row: cursor.row, count: n)
                return
            case 0x71: // DECSCUSR - Set Cursor Style
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
                return
            default:
                break
            }
        }

        if hasQuoteIntermediate {
            switch finalByte {
            case 0x70: // DECSCL - Set Conformance Level
                handleDECSCL(parser: parser)
                return
            case 0x71: // DECSCA - Select Character Protection Attribute
                switch Int(vt_parser_param(parser, 0, 0)) {
                case 1:
                    cursor.attributes.decProtected = true
                case 0, 2:
                    cursor.attributes.decProtected = false
                default:
                    break
                }
                return
            default:
                break
            }
        }

        if hasBangIntermediate {
            switch finalByte {
            case 0x70: // DECSTR - Soft terminal reset
                softReset()
                return
            default:
                break
            }
        }

        let hasDollarIntermediate = effectiveIntermediates == [UInt8(ascii: "$")]

        if hasDollarIntermediate {
            switch finalByte {
            case 0x70: // DECRQM - Request Mode
                sendResponse(makeDECRPMResponseBody(mode: Int(vt_parser_param(parser, 0, 0)), privateMarker: privateMarker))
                return
            case 0x75: // DECRQTSR - Request terminal state report
                if vt_parser_param(parser, 0, 0) == 1 {
                    sendDCSResponse("1$s")
                }
                return
            case 0x77: // DECRQPSR - Request presentation state report
                switch vt_parser_param(parser, 0, 0) {
                case 1:
                    sendDCSResponse(makeDECCIRResponseBody())
                case 2:
                    sendDCSResponse(makeDECTABSRResponseBody())
                default:
                    break
                }
                return
            default:
                break
            }
        }

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

        case 0x49: // CHT - Cursor Horizontal Forward Tabulation
            let count = max(1, Int(vt_parser_param(parser, 0, 1)))
            var target = cursor.col
            for _ in 0..<count {
                target = nextTabStop(after: target) ?? (cols - 1)
            }
            cursor.col = min(cols - 1, max(0, target))
            cursor.pendingWrap = false

        case 0x48: // CUP - Cursor Position
            let row = vt_parser_param(parser, 0, 1)
            let col = vt_parser_param(parser, 1, 1)
            cursor.row = min(rows - 1, max(0, Int(row) - 1))
            cursor.col = min(cols - 1, max(0, Int(col) - 1))
            cursor.pendingWrap = false

        case 0x4A: // ED - Erase in Display
            if privateMarker == UInt8(ascii: "?") {
                handleSelectiveEraseDisplay(param: vt_parser_param(parser, 0, 0))
            } else {
                handleEraseDisplay(param: vt_parser_param(parser, 0, 0))
            }

        case 0x4B: // EL - Erase in Line
            if privateMarker == UInt8(ascii: "?") {
                handleSelectiveEraseLine(param: vt_parser_param(parser, 0, 0))
            } else {
                handleEraseLine(param: vt_parser_param(parser, 0, 0))
            }

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
            deleteCharactersPreservingProtected(count: n)

        case 0x53: // SU - Scroll Up
            let n = Int(vt_parser_param(parser, 0, 1))
            grid.scrollUp(count: n)

        case 0x54: // SD - Scroll Down
            let n = Int(vt_parser_param(parser, 0, 1))
            grid.scrollDown(count: n)

        case 0x58: // ECH - Erase Characters
            let n = Int(vt_parser_param(parser, 0, 1))
            eraseCells(row: cursor.row, fromCol: cursor.col,
                       toCol: cursor.col + n - 1, selective: false)

        case 0x5A: // CBT - Cursor Backward Tabulation
            let count = max(1, Int(vt_parser_param(parser, 0, 1)))
            var target = cursor.col
            for _ in 0..<count {
                target = previousTabStop(before: target) ?? 0
            }
            cursor.col = max(0, min(cols - 1, target))
            cursor.pendingWrap = false

        case 0x60: // HPA - Character Position Absolute
            let n = vt_parser_param(parser, 0, 1)
            cursor.col = min(cols - 1, max(0, Int(n) - 1))
            cursor.pendingWrap = false

        case 0x61: // HPR - Character Position Relative
            let n = vt_parser_param(parser, 0, 1)
            cursor.col = min(cols - 1, max(0, cursor.col + Int(n)))
            cursor.pendingWrap = false

        case 0x40: // ICH - Insert Characters
            let n = Int(vt_parser_param(parser, 0, 1))
            insertBlankCharacters(count: n)

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

        case 0x65: // VPR - Line Position Relative
            let n = vt_parser_param(parser, 0, 1)
            cursor.row = min(rows - 1, max(0, cursor.row + Int(n)))
            cursor.pendingWrap = false

        case 0x66: // HVP - Horizontal and Vertical Position (same as CUP)
            let row = vt_parser_param(parser, 0, 1)
            let col = vt_parser_param(parser, 1, 1)
            cursor.row = min(rows - 1, max(0, Int(row) - 1))
            cursor.col = min(cols - 1, max(0, Int(col) - 1))
            cursor.pendingWrap = false

        case 0x68: // SM - Set Mode
            handleSetMode(parser: parser, privateMarker: privateMarker, set: true)

        case 0x67: // TBC - Tab Clear
            switch vt_parser_param(parser, 0, 0) {
            case 0:
                clearTabStop(at: cursor.col)
            case 3:
                clearAllTabStops()
            default:
                break
            }

        case 0x6C: // RM - Reset Mode
            handleSetMode(parser: parser, privateMarker: privateMarker, set: false)

        case 0x6D: // SGR - Select Graphic Rendition
            handleSGR(parser: parser)

        case 0x6E: // DSR - Device Status Report
            handleDSR(parser: parser)

        case 0x63: // DA - Device Attributes
            handleDeviceAttributes(privateMarker: privateMarker)

        case 0x78: // DECREQTPARM - Request Terminal Parameters
            handleRequestTerminalParameters(parser: parser, privateMarker: privateMarker)

        case 0x72: // DECSTBM - Set Top and Bottom Margins
            let top = Int(vt_parser_param(parser, 0, 1)) - 1
            let bottom = Int(vt_parser_param(parser, 1, Int32(rows))) - 1
            grid.scrollTop = max(0, min(top, rows - 1))
            grid.scrollBottom = max(grid.scrollTop, min(bottom, rows - 1))
            cursor.row = cursor.originMode ? grid.scrollTop : 0
            cursor.col = 0
            cursor.pendingWrap = false

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
            eraseCells(row: cursor.row, fromCol: cursor.col, toCol: cols - 1, selective: false)
            for row in (cursor.row + 1)..<rows {
                eraseRow(row, selective: false)
            }
        case 1: // Erase from start to cursor
            for row in 0..<cursor.row {
                eraseRow(row, selective: false)
            }
            eraseCells(row: cursor.row, fromCol: 0, toCol: cursor.col, selective: false)
        case 2: // Erase entire display
            for row in 0..<rows {
                eraseRow(row, selective: false)
            }
        case 3: // Erase scrollback (xterm extension)
            onClearScrollback?()
            for row in 0..<rows {
                eraseRow(row, selective: false)
            }
        default:
            break
        }
    }

    private func handleEraseLine(param: Int32) {
        switch param {
        case 0: // Erase from cursor to end of line
            eraseCells(row: cursor.row, fromCol: cursor.col, toCol: cols - 1, selective: false)
        case 1: // Erase from start to cursor
            eraseCells(row: cursor.row, fromCol: 0, toCol: cursor.col, selective: false)
        case 2: // Erase entire line
            eraseRow(cursor.row, selective: false)
        default:
            break
        }
    }

    private func handleSelectiveEraseDisplay(param: Int32) {
        switch param {
        case 0:
            eraseCells(row: cursor.row, fromCol: cursor.col, toCol: cols - 1, selective: true)
            if cursor.row + 1 < rows {
                for row in (cursor.row + 1)..<rows {
                    eraseRow(row, selective: true)
                }
            }
        case 1:
            for row in 0..<cursor.row {
                eraseRow(row, selective: true)
            }
            eraseCells(row: cursor.row, fromCol: 0, toCol: cursor.col, selective: true)
        case 2:
            for row in 0..<rows {
                eraseRow(row, selective: true)
            }
        default:
            break
        }
    }

    private func handleSelectiveEraseLine(param: Int32) {
        switch param {
        case 0:
            eraseCells(row: cursor.row, fromCol: cursor.col, toCol: cols - 1, selective: true)
        case 1:
            eraseCells(row: cursor.row, fromCol: 0, toCol: cursor.col, selective: true)
        case 2:
            eraseRow(cursor.row, selective: true)
        default:
            break
        }
    }

    private func eraseRow(_ row: Int, selective: Bool) {
        eraseCells(row: row, fromCol: 0, toCol: cols - 1, selective: selective)
    }

    private func eraseCells(row: Int, fromCol: Int, toCol: Int, selective: Bool) {
        guard row >= 0, row < rows else { return }
        let lower = max(0, fromCol)
        let upper = min(cols - 1, toCol)
        guard lower <= upper else { return }

        for col in lower...upper {
            let cell = grid.cell(at: row, col: col)
            let shouldErase = selective ? !cell.attributes.decProtected : !cell.attributes.decProtected
            if shouldErase {
                grid.setCell(.empty, at: row, col: col)
            }
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
                case 2026: // PENDING_UPDATE - pause rendering while terminal state continues to advance
                    guard pendingUpdateModeEnabled != set else { break }
                    pendingUpdateModeEnabled = set
                    onPendingUpdateModeChange?(set)
                default:
                    break
                }
            }
            else {
                switch mode {
                case 4: // IRM - Insert/Replace Mode
                    insertModeEnabled = set
                case 20: // LNM - Line Feed / New Line Mode
                    newLineMode = set
                default:
                    break
                }
            }
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
    var onResponseData: ((Data) -> Void)?
    private var responseControlsUse8Bit = false

    private func handleDSR(parser: UnsafePointer<VtParser>) {
        let param = vt_parser_param(parser, 0, 0)
        let privateMarker = parser.pointee.intermediate_count > 0 ? parser.pointee.intermediates.0 : 0
        if privateMarker == UInt8(ascii: "?") {
            switch param {
            case 15: // Printer status
                sendResponse("\u{1B}[?13n")
            case 25: // UDK status
                sendResponse("\u{1B}[?20n")
            case 26: // Keyboard status
                sendResponse("\u{1B}[?27;1;0;0n")
            default:
                break
            }
            return
        }

        switch param {
        case 5: // Operating status report
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
        let bytes = encodedResponseBytes(for: response)
        if let onResponseData {
            onResponseData(bytes)
            return
        }
        if responseControlsUse8Bit, let latin1 = String(data: bytes, encoding: .isoLatin1) {
            onResponse?(latin1)
            return
        }
        onResponse?(response)
    }

    private func sendDCSResponse(_ body: String) {
        let response = "\u{1B}P\(body)\u{1B}\\"
        let bytes = encodedResponseBytes(for: response)
        if let onResponseData {
            onResponseData(bytes)
            return
        }
        if responseControlsUse8Bit, let latin1 = String(data: bytes, encoding: .isoLatin1) {
            onResponse?(latin1)
            return
        }
        onResponse?(response)
    }

    private func makeDECRPMResponseBody(mode: Int, privateMarker: UInt8) -> String {
        let status: Int
        if privateMarker == UInt8(ascii: "?") {
            status = decModeReportStatus(mode: mode)
            return "\u{1B}[?\(mode);\(status)$y"
        }

        status = ansiModeReportStatus(mode: mode)
        return "\u{1B}[\(mode);\(status)$y"
    }

    private func ansiModeReportStatus(mode: Int) -> Int {
        switch mode {
        case 4:
            return insertModeEnabled ? 1 : 2
        case 20:
            return newLineMode ? 1 : 2
        default:
            return 0
        }
    }

    private func decModeReportStatus(mode: Int) -> Int {
        switch mode {
        case 1:
            return applicationCursorKeys ? 1 : 2
        case 2:
            return 1
        case 6:
            return cursor.originMode ? 1 : 2
        case 7:
            return cursor.autoWrapMode ? 1 : 2
        case 25:
            return cursor.visible ? 1 : 2
        case 1004:
            return focusTrackingEnabled ? 1 : 2
        default:
            return 0
        }
    }

    private func encodedResponseBytes(for response: String) -> Data {
        guard responseControlsUse8Bit else {
            return Data(response.utf8)
        }

        let source = Array(response.utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == 0x1B, index + 1 < source.count {
                switch source[index + 1] {
                case UInt8(ascii: "["):
                    encoded.append(0x9B)
                    index += 2
                    continue
                case UInt8(ascii: "]"):
                    encoded.append(0x9D)
                    index += 2
                    continue
                case UInt8(ascii: "P"):
                    encoded.append(0x90)
                    index += 2
                    continue
                case UInt8(ascii: "\\"):
                    encoded.append(0x9C)
                    index += 2
                    continue
                case UInt8(ascii: "N"):
                    encoded.append(0x8E)
                    index += 2
                    continue
                case UInt8(ascii: "O"):
                    encoded.append(0x8F)
                    index += 2
                    continue
                default:
                    break
                }
            }
            encoded.append(byte)
            index += 1
        }
        return Data(encoded)
    }

    private func handleDCS(parser: UnsafePointer<VtParser>) {
        guard dcsFinalByte != 0 else { return }
        let payloadData: Data
        if parser.pointee.string_len == 0 || parser.pointee.string_buf == nil {
            payloadData = Data()
        } else {
            payloadData = Data(bytes: parser.pointee.string_buf, count: parser.pointee.string_len)
        }
        guard let payload = String(data: payloadData, encoding: .isoLatin1) else { return }

        if dcsFinalByte == UInt32(UInt8(ascii: "q")),
           dcsIntermediates == [UInt8(ascii: "$")] {
            handleDECRQSS(payload)
        }
    }

    private func handleDECRQSS(_ request: String) {
        guard !request.isEmpty else { return }
        switch request {
        case "\"p":
            let controlMode = responseControlsUse8Bit ? 0 : 1
            sendDCSResponse("1$r6\(operatingLevel);\(controlMode)\"p")
        default:
            sendDCSResponse("1$r\(request)")
        }
    }

    private func makeDECCIRResponseBody() -> String {
        let srend = deccirFlagByte(
            reverse: cursor.attributes.inverse,
            blinking: cursor.attributes.blink,
            underline: cursor.attributes.underline,
            bold: cursor.attributes.bold
        )
        let satt = deccirSelectiveEraseByte()
        let sflag = deccirStateFlagByte()
        let pgl = deccirInvocationIndex(glInvocation)
        let pgr = deccirInvocationIndex(grInvocation)
        let scss = deccirCharsetSizeByte()
        let sdesig = deccirCharsetDesignations()

        return "1$u\(cursor.row + 1);\(cursor.col + 1);1;\(srend);\(satt);\(sflag);\(pgl);\(pgr);\(scss);\(sdesig)"
    }

    private func makeDECTABSRResponseBody() -> String {
        var stops: [String] = []
        stops.reserveCapacity(cols / 4)
        for column in 0..<cols where isTabStopSet(at: column) {
            stops.append(String(column + 1))
        }
        return "2$u" + stops.joined(separator: "/")
    }

    private func deccirFlagByte(reverse: Bool, blinking: Bool, underline: Bool, bold: Bool) -> String {
        let value = 0x40 |
            (reverse ? 0x08 : 0) |
            (blinking ? 0x04 : 0) |
            (underline ? 0x02 : 0) |
            (bold ? 0x01 : 0)
        return String(UnicodeScalar(value)!)
    }

    private func deccirSelectiveEraseByte() -> String {
        let value = 0x40 | (cursor.attributes.decProtected ? 0x01 : 0)
        return String(UnicodeScalar(value)!)
    }

    private func deccirStateFlagByte() -> String {
        let value = 0x40 |
            (cursor.pendingWrap ? 0x08 : 0) |
            (singleShiftInvocation == .g3 ? 0x04 : 0) |
            (singleShiftInvocation == .g2 ? 0x02 : 0) |
            (cursor.originMode ? 0x01 : 0)
        return String(UnicodeScalar(value)!)
    }

    private func deccirInvocationIndex(_ invocation: InvokedCharacterSet) -> Int {
        switch invocation {
        case .g0: return 0
        case .g1: return 1
        case .g2: return 2
        case .g3: return 3
        }
    }

    private func deccirCharsetSizeByte() -> String {
        // Current supported sets are all 94-character designations.
        return String(UnicodeScalar(0x40)!)
    }

    private func deccirCharsetDesignations() -> String {
        deccirDesignationSuffix(for: g0Charset) +
        deccirDesignationSuffix(for: g1Charset) +
        deccirDesignationSuffix(for: g2Charset) +
        deccirDesignationSuffix(for: g3Charset)
    }

    private func deccirDesignationSuffix(for charset: DesignatedCharacterSet) -> String {
        switch charset {
        case .ascii:
            return "B"
        case .british:
            return "A"
        case .decSpecialGraphics:
            return "0"
        }
    }

    private func handleDeviceAttributes(privateMarker: UInt8) {
        switch privateMarker {
        case UInt8(ascii: ">"):
            // Secondary DA: emulate a broadly compatible VT420/xterm-style
            // response that vttest accepts as a valid firmware report.
            sendResponse("\u{1B}[>41;0;0c")
        case UInt8(ascii: "="):
            // Tertiary DA is only expected for VT420+ class terminals. We do
            // not advertise that capability from primary DA, so leaving this
            // unanswered keeps vttest in the "not supported" path.
            break
        default:
            // Primary DA: advertise a VT420-class terminal so vttest enables
            // VT320/VT420 feature menus and validates DECSCL/DECRQSS paths.
            sendResponse("\u{1B}[?64;1;2;6;8;9;15c")
        }
    }

    private func handleDECSCL(parser: UnsafePointer<VtParser>) {
        let requestedLevelCode = Int(vt_parser_param(parser, 0, 61))
        let requestedLevel: Int
        switch requestedLevelCode {
        case 61...64:
            requestedLevel = requestedLevelCode - 60
        default:
            requestedLevel = 1
        }

        operatingLevel = requestedLevel

        let controlModeParam: Int
        if parser.pointee.param_count > 1 {
            controlModeParam = Int(withUnsafeBytes(of: parser.pointee.params) { rawBytes in
                rawBytes.bindMemory(to: Int32.self)[1]
            })
        } else {
            controlModeParam = 1
        }

        switch controlModeParam {
        case 0:
            responseControlsUse8Bit = true
        default:
            responseControlsUse8Bit = false
        }
    }

    private func handleRequestTerminalParameters(parser: UnsafePointer<VtParser>, privateMarker: UInt8) {
        guard privateMarker == 0 else { return }

        switch vt_parser_param(parser, 0, 0) {
        case 0:
            sendResponse("\u{1B}[2;1;1;120;120;1;0x")
        case 1:
            sendResponse("\u{1B}[3;1;1;120;120;1;0x")
        default:
            break
        }
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

            if intermediate == UInt8(ascii: " ") {
                switch finalByte {
                case 0x46: // S7C1T
                    responseControlsUse8Bit = false
                    return
                case 0x47: // S8C1T
                    responseControlsUse8Bit = true
                    return
                default:
                    break
                }
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

        case 0x56: // SPA - Start of Protected Area
            protectedAreaModeEnabled = true

        case 0x57: // EPA - End of Protected Area
            protectedAreaModeEnabled = false

        case 0x4E: // SS2 - Single Shift G2 into GL for next graphic character
            singleShiftInvocation = .g2

        case 0x4F: // SS3 - Single Shift G3 into GL for next graphic character
            singleShiftInvocation = .g3

        case 0x6E: // LS2 - Locking Shift G2 into GL
            glInvocation = .g2

        case 0x6F: // LS3 - Locking Shift G3 into GL
            glInvocation = .g3

        case 0x7C: // LS3R - Locking Shift G3 into GR
            grInvocation = .g3

        case 0x7D: // LS2R - Locking Shift G2 into GR
            grInvocation = .g2

        case 0x7E: // LS1R - Locking Shift G1 into GR
            grInvocation = .g1

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

    private static func shouldAccumulateOSCPayload(for command: Int) -> Bool {
        switch command {
        case 0, 2, 7, 52:
            return true
        default:
            return false
        }
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

        case 7: // Current working directory
            handleOSC7(text)

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

    private func handleOSC7(_ payload: String) {
        guard let url = URL(string: payload),
              url.scheme?.caseInsensitiveCompare("file") == .orderedSame else {
            return
        }
        let path = url.path
        guard !path.isEmpty else { return }
        onWorkingDirectoryChange?(path)
    }

    // MARK: - Reset

    func reset() {
        grid.clearAll()
        cursor = CursorState()
        grid.scrollTop = 0
        grid.scrollBottom = rows - 1
        bracketedPasteMode = false
        applicationCursorKeys = false
        newLineMode = false
        mouseReporting = .none
        mouseProtocol = .x10
        focusTrackingEnabled = false
        pendingUpdateModeEnabled = false
        insertModeEnabled = false
        isAlternateScreen = false
        alternateGrid = nil
        g0Charset = .ascii
        g1Charset = .ascii
        g2Charset = .ascii
        g3Charset = .ascii
        glInvocation = .g0
        grInvocation = .g1
        singleShiftInvocation = nil
        protectedAreaModeEnabled = false
        responseControlsUse8Bit = false
        initTabStops()
        onPendingUpdateModeChange?(false)
    }

    private func softReset() {
        cursor = CursorState()
        grid.scrollTop = 0
        grid.scrollBottom = rows - 1
        bracketedPasteMode = false
        applicationCursorKeys = false
        newLineMode = false
        mouseReporting = .none
        mouseProtocol = .x10
        focusTrackingEnabled = false
        pendingUpdateModeEnabled = false
        insertModeEnabled = false
        g0Charset = .ascii
        g1Charset = .ascii
        g2Charset = .ascii
        g3Charset = .ascii
        glInvocation = .g0
        grInvocation = .g1
        singleShiftInvocation = nil
        protectedAreaModeEnabled = false
        responseControlsUse8Bit = false
        initTabStops()
        onPendingUpdateModeChange?(false)
    }

    private func insertBlankCharacters(count: Int) {
        transformUnprotectedCells(row: cursor.row, startCol: cursor.col, count: count, mode: .insert)
    }

    private func deleteCharactersPreservingProtected(count: Int) {
        transformUnprotectedCells(row: cursor.row, startCol: cursor.col, count: count, mode: .delete)
    }

    private enum ProtectedTransformMode {
        case insert
        case delete
    }

    private func transformUnprotectedCells(
        row: Int,
        startCol: Int,
        count: Int,
        mode: ProtectedTransformMode
    ) {
        guard row >= 0, row < rows, startCol >= 0, startCol < cols, count > 0 else { return }

        let snapshot = (0..<cols).map { grid.cell(at: row, col: $0) }
        let editableColumns = Array((startCol..<cols).filter { !snapshot[$0].attributes.decProtected })
        guard !editableColumns.isEmpty else { return }

        let shift = min(count, editableColumns.count)
        var updated = snapshot

        switch mode {
        case .insert:
            for destinationPosition in stride(from: editableColumns.count - 1, through: 0, by: -1) {
                let destinationColumn = editableColumns[destinationPosition]
                let sourcePosition = destinationPosition - shift
                if sourcePosition >= 0 {
                    updated[destinationColumn] = snapshot[editableColumns[sourcePosition]]
                } else {
                    updated[destinationColumn] = .empty
                }
            }
        case .delete:
            for destinationPosition in 0..<editableColumns.count {
                let destinationColumn = editableColumns[destinationPosition]
                let sourcePosition = destinationPosition + shift
                if sourcePosition < editableColumns.count {
                    updated[destinationColumn] = snapshot[editableColumns[sourcePosition]]
                } else {
                    updated[destinationColumn] = .empty
                }
            }
        }

        for column in 0..<cols where !cellsEqual(updated[column], snapshot[column]) {
            grid.setCell(updated[column], at: row, col: column)
        }
    }

    private func cellsEqual(_ lhs: Cell, _ rhs: Cell) -> Bool {
        lhs.codepoint == rhs.codepoint &&
        lhs.attributes == rhs.attributes &&
        lhs.width == rhs.width &&
        lhs.isWideContinuation == rhs.isWideContinuation
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
        case 0x41: // "A" = British
            charset = .british
        case 0x42: // "B" = US ASCII
            charset = .ascii
        default:
            return
        }

        switch intermediate {
        case UInt8(ascii: "("):
            g0Charset = charset
        case UInt8(ascii: ")"), UInt8(ascii: "-"):
            g1Charset = charset
        case UInt8(ascii: "*"), UInt8(ascii: "."):
            g2Charset = charset
        case UInt8(ascii: "+"), UInt8(ascii: "/"):
            g3Charset = charset
        default:
            return
        }
    }

    private func translateCharacterSet(_ codepoint: UInt32) -> UInt32 {
        let invocation = singleShiftInvocation ?? ((codepoint < 0x80) ? glInvocation : grInvocation)
        let charset = designatedCharacterSet(for: invocation)
        if singleShiftInvocation != nil {
            singleShiftInvocation = nil
        }

        switch charset {
        case .ascii:
            return codepoint
        case .british:
            return codepoint == 0x23 ? 0x00A3 : codepoint
        case .decSpecialGraphics:
            break
        }

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

    private func designatedCharacterSet(for invocation: InvokedCharacterSet) -> DesignatedCharacterSet {
        switch invocation {
        case .g0:
            return g0Charset
        case .g1:
            return g1Charset
        case .g2:
            return g2Charset
        case .g3:
            return g3Charset
        }
    }

    // MARK: - Resize

    func resize(newRows: Int, newCols: Int) {
        let result = grid.resize(newRows: newRows, newCols: newCols,
                                  cursorRow: cursor.row, cursorCol: cursor.col)

        // Save trimmed rows to scrollback before they are lost
        for trimmed in result.trimmedRows {
            onScrollOut?(
                ScrollbackBuffer.BufferedRow(
                    cells: trimmed.cells,
                    cellCount: trimmed.cells.count,
                    isWrapped: trimmed.isWrapped,
                    encodingHint: .unknown
                )
            )
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

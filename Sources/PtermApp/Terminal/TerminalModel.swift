import Compression
import Darwin
import Foundation
import PtermCore

/// Core terminal emulation model.
///
/// Owns the character grid and cursor state. Processes VT parser actions
/// to update the terminal display. This is the bridge between the C VT parser
/// and the Swift rendering layer.
final class TerminalModel {
    @_silgen_name("shm_open")
    private static func posixShmOpen(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32

    private struct KittyImageChunkAccumulator {
        let startRow: Int
        let startCol: Int
        let transmission: UInt8
        let compression: UInt8?
        let pixelWidth: Int?
        let pixelHeight: Int?
        let columnSpan: Int
        let rowSpan: Int
        let format: TerminalImagePayloadFormat?
        let byteOffset: Int
        let byteCount: Int?
        let encodedPayloadFileURL: URL
    }

    private struct KittyGraphicsControl {
        var action: UInt8 = UInt8(ascii: "t")
        var transmission: UInt8 = UInt8(ascii: "d")
        var compression: UInt8?
        var hasMoreChunks = false
        var byteOffset = 0
        var byteCount: Int?
        var imageIndex: Int?
        var columnSpan = 1
        var rowSpan = 1
        var pixelWidth: Int?
        var pixelHeight: Int?
        var formatCode: Int?
        var encodedPayloadStart = 0
    }

    enum DeferredKittyImagePayloadSource {
        case file(URL)
        case encodedData(Data)
    }

    struct DeferredKittyImagePayloadJob {
        let imageIndex: Int
        let encodedPayloadSource: DeferredKittyImagePayloadSource
        let transmission: UInt8
        let compression: UInt8?
        let format: TerminalImagePayloadFormat?
        let pixelWidth: Int?
        let pixelHeight: Int?
        let columnSpan: Int
        let rowSpan: Int
        let byteOffset: Int
        let byteCount: Int?
    }

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

    /// Application keypad mode (DECPAM/DECPNM)
    var applicationKeypadMode: Bool = false

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
    var onKittyImagePayload: ((_ index: Int, _ data: Data, _ format: TerminalImagePayloadFormat, _ pixelWidth: Int?, _ pixelHeight: Int?, _ columns: Int?, _ rows: Int?) -> Void)?

    /// I/O hook text sink.  When non-nil, each printed codepoint is forwarded
    /// to the hook manager for line/idle mode text capture.
    /// Set by TerminalController when hooks are active; nil otherwise (zero cost).
    var hookTextSink: ((UInt32) -> Void)?

    /// Called when the terminal switches between normal and alternate screen
    /// buffers.  The Bool is true when entering alternate screen.
    var onAlternateScreenChange: ((Bool) -> Void)?

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
    private var operatingLevel: Int = 5
    private var reportedLinesPerScreen: Int

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
        case utf8
        case sgr
    }

    var mouseProtocol: MouseProtocol = .x10
    var focusTrackingEnabled: Bool = false
    private(set) var pendingUpdateModeEnabled: Bool = false
    private(set) var reverseVideoEnabled = false
    private(set) var kittyKeyboardProtocolEnabled = false
    private(set) var modifyOtherKeysMode = 0
    private(set) var formatOtherKeysMode = 0
    private(set) var modifyOtherKeysMask = 0
    private var insertModeEnabled = false
    private var protectedAreaModeEnabled = false
    private var nextKittyImagePlaceholderIndex = 1
    private var kittyImageChunkAccumulators: [Int: KittyImageChunkAccumulator] = [:]
    private var pendingKittyImageChunkContinuationIndex: Int?
    private var previousPrintableEndsWithZWJ = false
    private static let answerbackMessage = "pterm"
    static let kittyImageEncodedPayloadDirectory: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pterm-kitty-image-payloads", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }()

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.reportedLinesPerScreen = rows
        self.grid = TerminalGrid(rows: rows, cols: cols)
        initTabStops()
    }

    deinit {
        for accumulator in kittyImageChunkAccumulators.values {
            Self.removeKittyEncodedPayloadFile(at: accumulator.encodedPayloadFileURL)
        }
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
        var wordIndex = (column + 1) / 64
        let bitOffset = (column + 1) % 64
        guard wordIndex < tabStopWords.count else { return nil }

        var word = tabStopWords[wordIndex] & (~UInt64(0) << UInt64(bitOffset))
        while true {
            if word != 0 {
                let bit = word.trailingZeroBitCount
                let target = wordIndex * 64 + bit
                if target < cols {
                    return target
                }
                return nil
            }
            wordIndex += 1
            guard wordIndex < tabStopWords.count else { return nil }
            word = tabStopWords[wordIndex]
        }
        return nil
    }

    private func previousTabStop(before column: Int) -> Int? {
        guard column > 0 else { return nil }
        var wordIndex = (column - 1) / 64
        let bitOffset = (column - 1) % 64
        guard wordIndex < tabStopWords.count else { return nil }

        var word = tabStopWords[wordIndex]
        if bitOffset < 63 {
            word &= ~UInt64(0) >> UInt64(63 - bitOffset)
        }

        while true {
            if word != 0 {
                let bit = 63 - word.leadingZeroBitCount
                return wordIndex * 64 + bit
            }
            guard wordIndex > 0 else { return nil }
            wordIndex -= 1
            word = tabStopWords[wordIndex]
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

    private func lineAttribute(at row: Int) -> TerminalLineAttribute {
        grid.lineAttribute(at: row)
    }

    @inline(__always)
    private func visibleColumnCount(for row: Int) -> Int {
        if grid.hasOnlySingleWidthLines {
            return cols
        }
        return max(1, lineAttribute(at: row).isDoubleWidth ? max(cols / 2, 1) : cols)
    }

    @inline(__always)
    private func clampColumn(_ column: Int, for row: Int) -> Int {
        min(max(column, 0), visibleColumnCount(for: row) - 1)
    }

    private func clampCursorToVisibleLineWidth() {
        guard rows > 0, cols > 0 else { return }
        cursor.row = min(max(cursor.row, 0), rows - 1)
        let maxVisibleColumn = visibleColumnCount(for: cursor.row) - 1
        if cursor.col > maxVisibleColumn {
            cursor.col = maxVisibleColumn
            cursor.pendingWrap = false
        } else if cursor.col < 0 {
            cursor.col = 0
            cursor.pendingWrap = false
        }
    }

    private func setCurrentLineAttribute(_ attribute: TerminalLineAttribute) {
        grid.setLineAttribute(attribute, at: cursor.row)
        clampCursorToVisibleLineWidth()
    }

    private func applyCharacterResize(
        rows targetRows: Int,
        cols targetCols: Int,
        clearDisplay: Bool = false,
        resetCursorAndMargins: Bool = false
    ) {
        let normalizedRows = max(1, targetRows)
        let normalizedCols = max(1, targetCols)
        if normalizedRows != rows || normalizedCols != cols {
            resize(newRows: normalizedRows, newCols: normalizedCols)
        }
        if clearDisplay {
            grid.clearAll()
            alternateGrid?.clearAll()
        }
        if resetCursorAndMargins {
            cursor = CursorState()
            grid.scrollTop = 0
            grid.scrollBottom = rows - 1
            initTabStops()
        }
        onWindowResizeRequest?(normalizedRows, normalizedCols)
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

    var canUseKnownWideUTF8GroundFastPath: Bool {
        !insertModeEnabled
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
            return consumeGroundPrintableCodepointsFastPathPrefix(codepoints)
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
    func consumeGroundExecuteFastPath(_ codepoint: UInt32) -> Bool {
        switch codepoint {
        case 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F:
            handleExecute(codepoint)
            return true
        default:
            return false
        }
    }

    func handleKnownDoubleWidthCodepointRun(_ codepoints: UnsafeBufferPointer<UInt32>) {
        guard let baseAddress = codepoints.baseAddress, !codepoints.isEmpty else { return }
        handleDoubleWidthCodepointRun(baseAddress, count: codepoints.count)
    }

    @discardableResult
    private func consumeGroundPrintableCodepointsFastPathPrefix(_ codepoints: UnsafeBufferPointer<UInt32>) -> Int {
        guard !codepoints.isEmpty else { return 0 }
        var index = 0
        while index < codepoints.count {
            let codepoint = codepoints[index]

            switch codepoint {
            case 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F:
                handleExecute(codepoint)
                index += 1
                continue
            case 0x1B, 0x18, 0x1A, 0x7F, 0x00...0x1F:
                return index
            default:
                break
            }

            let width = fastGroundPathWidth(of: codepoint)
            if width == 1 {
                let runStart = index
                var runCount = 1
                while runStart + runCount < codepoints.count {
                    let next = codepoints[runStart + runCount]
                    let nextWidth = fastGroundPathWidth(of: next)
                    guard nextWidth == 1 else { break }
                    runCount += 1
                }
                handleSingleWidthCodepointRun(codepoints.baseAddress!.advanced(by: runStart), count: runCount)
                index += runCount
            } else if width == 2 {
                let runStart = index
                var runCount = 1
                if isCommonFastPathWideCodepoint(codepoint) {
                    while runStart + runCount < codepoints.count {
                        let next = codepoints[runStart + runCount]
                        if isCommonFastPathWideCodepoint(next) {
                            runCount += 1
                            continue
                        }
                        let nextWidth = fastGroundPathWidth(of: next)
                        guard nextWidth == 2 else { break }
                        runCount += 1
                    }
                } else {
                    while runStart + runCount < codepoints.count {
                        let next = codepoints[runStart + runCount]
                        let nextWidth = fastGroundPathWidth(of: next)
                        guard nextWidth == 2 else { break }
                        runCount += 1
                    }
                }
                handleDoubleWidthCodepointRun(codepoints.baseAddress!.advanced(by: runStart), count: runCount)
                index += runCount
            } else {
                handlePrint(codepoint)
                index += 1
            }
        }

        return index
    }

    private func fastGroundPathWidth(of codepoint: UInt32) -> Int {
        if requiresClusterAwarePrint(codepoint) { return 0 }
        if codepoint >= 0x20 && codepoint <= 0x7E { return 1 }
        if codepoint < 0x3000 {
            if codepoint >= 0x00A0 && codepoint <= 0x02FF { return 1 }
            if codepoint >= 0x0300 && codepoint <= 0x036F { return 0 }
            if codepoint >= 0x0370 && codepoint <= 0x03FF { return 1 }
            if codepoint >= 0x1AB0 && codepoint <= 0x1AFF { return 0 }
            if codepoint >= 0x1DC0 && codepoint <= 0x1DFF { return 0 }
            if codepoint >= 0x2000 && codepoint <= 0x206F {
                if codepoint == 0x200B || codepoint == 0x200C || codepoint == 0x200D || codepoint == 0x2060 {
                    return 0
                }
                return 1
            }
            if codepoint >= 0x20D0 && codepoint <= 0x20FF { return 0 }
            if codepoint >= 0x2100 && codepoint <= 0x214F { return 1 }
            if codepoint >= 0x2190 && codepoint <= 0x21FF { return 1 }
            if codepoint >= 0x2200 && codepoint <= 0x22FF { return 1 }
        } else if codepoint < 0x10000 {
            if codepoint >= 0x3000 && codepoint <= 0x303F { return 2 }
            if codepoint >= 0x3040 && codepoint <= 0x30FF { return 2 }
            if codepoint >= 0x3400 && codepoint <= 0x4DBF { return 2 }
            if codepoint >= 0x4E00 && codepoint <= 0x9FFF { return 2 }
            if codepoint >= 0xAC00 && codepoint <= 0xD7AF { return 2 }
            if codepoint >= 0xFE00 && codepoint <= 0xFE0F { return 0 }
            if codepoint >= 0xFE20 && codepoint <= 0xFE2F { return 0 }
            if codepoint == 0xFEFF { return 0 }
            if codepoint >= 0xFF01 && codepoint <= 0xFF60 { return 2 }
            if codepoint >= 0xFFE0 && codepoint <= 0xFFE6 { return 2 }
        } else if codepoint >= 0x1F300 && codepoint <= 0x1FAFF {
            return 2
        }

        return CharacterWidth.width(of: codepoint)
    }

    @inline(__always)
    private func isCommonFastPathWideCodepoint(_ codepoint: UInt32) -> Bool {
        if codepoint >= 0x3000 && codepoint <= 0x303F { return true }
        if codepoint >= 0x3040 && codepoint <= 0x30FF { return true }
        if codepoint >= 0x3400 && codepoint <= 0x4DBF { return true }
        if codepoint >= 0x4E00 && codepoint <= 0x9FFF { return true }
        if codepoint >= 0xAC00 && codepoint <= 0xD7AF { return true }
        if codepoint >= 0xFF01 && codepoint <= 0xFF60 { return true }
        if codepoint >= 0xFFE0 && codepoint <= 0xFFE6 { return true }
        if codepoint >= 0x1F300 && codepoint <= 0x1FAFF { return true }
        return false
    }

    private func requiresClusterAwarePrint(_ codepoint: UInt32) -> Bool {
        isRegionalIndicator(codepoint) || isEmojiModifier(codepoint)
    }

    private func isRegionalIndicator(_ codepoint: UInt32) -> Bool {
        codepoint >= 0x1F1E6 && codepoint <= 0x1F1FF
    }

    private func isEmojiModifier(_ codepoint: UInt32) -> Bool {
        codepoint >= 0x1F3FB && codepoint <= 0x1F3FF
    }

    private func graphemeDisplayWidth(for cell: Cell) -> Int {
        if cell.containsGraphemeScalar(0x200D)
            || cell.containsGraphemeScalar(0x20E3)
            || cell.containsGraphemeScalar(where: isEmojiModifier) {
            return 2
        }
        if cell.graphemeScalarCount() == 2
            && isRegionalIndicator(cell.codepoint)
            && isRegionalIndicator(cell.lastGraphemeScalar()) {
            return 2
        }
        if cell.containsGraphemeScalar(0xFE0F) {
            return 2
        }
        return max(Int(cell.width), CharacterWidth.width(of: cell.codepoint), 1)
    }

    private func previousGraphemeAnchorPosition() -> (row: Int, col: Int)? {
        let visibleCols = visibleColumnCount(for: cursor.row)
        guard visibleCols > 0 else { return nil }
        var column = cursor.pendingWrap ? visibleCols - 1 : cursor.col - 1
        while column >= 0 {
            let cell = grid.cell(at: cursor.row, col: column)
            if cell.isWideContinuation {
                column -= 1
                continue
            }
            guard cell.codepoint != 0x20 || cell.hasGraphemeTail else { return nil }
            return (cursor.row, column)
        }
        return nil
    }

    private func tryAppendToPreviousGraphemeCluster(_ codepoint: UInt32, width: Int) -> Bool {
        guard let anchor = previousGraphemeAnchorPosition() else { return false }
        var cell = grid.cell(at: anchor.row, col: anchor.col)
        guard !cell.hasInlineImage, !cell.isWideContinuation else { return false }

        let lastScalar = cell.lastGraphemeScalar()
        let shouldAppend: Bool
        if width == 0 {
            shouldAppend = true
        } else if isEmojiModifier(codepoint) {
            shouldAppend = CharacterWidth.width(of: cell.codepoint) == 2 || cell.hasGraphemeTail
        } else if isRegionalIndicator(codepoint) {
            shouldAppend = cell.onlyScalarMatches(isRegionalIndicator)
        } else if lastScalar == 0x200D {
            shouldAppend = true
        } else {
            shouldAppend = false
        }
        guard shouldAppend, cell.appendGraphemeScalar(codepoint) else { return false }

        let oldWidth = Int(max(cell.width, 1))
        let newWidth = graphemeDisplayWidth(for: cell)
        let visibleCols = visibleColumnCount(for: anchor.row)
        guard anchor.col + newWidth <= visibleCols else { return false }

        cell.width = UInt8(newWidth)
        grid.setCell(cell, at: anchor.row, col: anchor.col)
        if newWidth == 2, anchor.col + 1 < visibleCols {
            let continuation = Cell(
                codepoint: 0,
                attributes: cell.attributes,
                width: 0,
                isWideContinuation: true
            )
            grid.setCell(continuation, at: anchor.row, col: anchor.col + 1)
        } else if oldWidth == 2, anchor.col + 1 < visibleCols {
            grid.setCell(.empty, at: anchor.row, col: anchor.col + 1)
        }

        cursor.pendingWrap = false
        cursor.col = min(anchor.col + newWidth, visibleCols - 1)
        if anchor.col + newWidth >= visibleCols, cursor.autoWrapMode {
            cursor.pendingWrap = true
            cursor.col = visibleCols - 1
        }
        return true
    }

    @inline(__always)
    private func shouldAttemptAppendToPreviousGraphemeCluster(_ codepoint: UInt32, width: Int) -> Bool {
        if width == 0 { return true }
        if isEmojiModifier(codepoint) || isRegionalIndicator(codepoint) { return true }
        return previousPrintableEndsWithZWJ
    }

    @discardableResult
    func consumeGroundASCIIBytesFastPathPrefix(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        guard !bytes.isEmpty else { return 0 }
        guard let baseAddress = bytes.baseAddress else { return 0 }

        var index = 0
        while index < bytes.count {
            if canUseDefaultSingleWidthASCIITextFastPath {
                let fastPathConsumed = consumeGroundTextASCIIBytesDefaultSingleWidthFastPathPrefix(
                    baseAddress.advanced(by: index),
                    count: bytes.count - index
                )
                if fastPathConsumed > 0 {
                    index += fastPathConsumed
                    continue
                }
            }

            let textRunCount = Int(
                vt_parser_scan_text_ascii_prefix(
                    baseAddress.advanced(by: index),
                    bytes.count - index
                )
            )
            if textRunCount > 0 {
                consumeGroundTextASCIIBytes(
                    baseAddress.advanced(by: index),
                    count: textRunCount
                )
                index += textRunCount
                continue
            }

            let byte = bytes[index]
            switch byte {
            case 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F:
                handleExecute(UInt32(byte))
                index += 1
            case 0x1B:
                guard index + 1 < bytes.count else { return index }
                let introducer = bytes[index + 1]
                if introducer == UInt8(ascii: "["),
                   let skippedCount = consumeCSIBytes(in: bytes, from: index) {
                    index += skippedCount
                } else if let skippedCount = consumeSimpleESCBytes(in: bytes, from: index) {
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

    @inline(__always)
    private func consumeGroundTextASCIIBytes(
        _ bytes: UnsafePointer<UInt8>,
        count: Int
    ) {
        if canUseDefaultSingleWidthASCIITextFastPath {
            consumeGroundTextASCIIBytesDefaultSingleWidthFastPath(bytes, count: count)
            return
        }

        var pointer = bytes
        var remainingCount = count

        while remainingCount > 0 {
            let printableCount = Int(
                vt_parser_scan_printable_ascii_prefix(
                    pointer,
                    remainingCount
                )
            )
            if printableCount > 0 {
                handleASCIIByteRun(
                    pointer,
                    count: printableCount,
                    containsSpace: true
                )
                pointer = pointer.advanced(by: printableCount)
                remainingCount -= printableCount
            }

            guard remainingCount > 0 else { break }

            switch pointer.pointee {
            case 0x09, 0x0A, 0x0D:
                handleExecute(UInt32(pointer.pointee))
                pointer = pointer.advanced(by: 1)
                remainingCount -= 1
            default:
                return
            }
        }
    }

    private var canUseDefaultSingleWidthASCIITextFastPath: Bool {
        grid.hasOnlySingleWidthLines &&
        !insertModeEnabled &&
        !protectedAreaModeEnabled &&
        cursor.attributes == .default
    }

    @inline(__always)
    private func consumeGroundTextASCIIBytesDefaultSingleWidthFastPath(
        _ bytes: UnsafePointer<UInt8>,
        count: Int
    ) {
        _ = consumeGroundTextASCIIBytesDefaultSingleWidthFastPathPrefix(bytes, count: count)
    }

    @discardableResult
    @inline(__always)
    private func consumeGroundTextASCIIBytesDefaultSingleWidthFastPathPrefix(
        _ bytes: UnsafePointer<UInt8>,
        count: Int
    ) -> Int {
        var pointer = bytes
        var remainingCount = count
        let visibleCols = cols
        let originalCount = count

        while remainingCount > 0 {
            let printableCount = Int(
                vt_parser_scan_printable_ascii_prefix(
                    pointer,
                    remainingCount
                )
            )
            if printableCount > 0 {
                var remainingPrintableBase = pointer
                var remainingPrintableCount = printableCount

                while remainingPrintableCount > 0 {
                    if cursor.pendingWrap {
                        cursor.col = 0
                        lineFeed()
                        grid.setWrapped(cursor.row, true)
                        cursor.pendingWrap = false
                    }

                    let available = visibleCols - cursor.col
                    guard available > 0 else { return originalCount - remainingCount }

                    let chunkCount = min(remainingPrintableCount, available)
                    grid.writeSingleWidthDefaultASCIIBytes(
                        remainingPrintableBase,
                        count: chunkCount,
                        atRow: cursor.row,
                        startCol: cursor.col
                    )

                    cursor.col += chunkCount
                    remainingPrintableBase = remainingPrintableBase.advanced(by: chunkCount)
                    remainingPrintableCount -= chunkCount

                    if cursor.col == visibleCols && remainingPrintableCount > 0 && cursor.autoWrapMode {
                        cursor.col = 0
                        lineFeed()
                        grid.setWrapped(cursor.row, true)
                        continue
                    }

                    if cursor.col >= visibleCols {
                        cursor.col = visibleCols - 1
                        if cursor.autoWrapMode {
                            cursor.pendingWrap = true
                        }
                    }
                }

                pointer = pointer.advanced(by: printableCount)
                remainingCount -= printableCount
                continue
            }

            switch pointer.pointee {
            case 0x09:
                let nextTab = nextTabStop(after: cursor.col) ?? (visibleCols - 1)
                cursor.col = min(nextTab, visibleCols - 1)
                cursor.pendingWrap = false
            case 0x0A:
                lineFeed()
            case 0x0D:
                cursor.col = 0
                cursor.pendingWrap = false
            default:
                return originalCount - remainingCount
            }

            pointer = pointer.advanced(by: 1)
            remainingCount -= 1
        }

        return originalCount
    }

    private func consumeSimpleESCBytes(
        in bytes: UnsafeBufferPointer<UInt8>,
        from startIndex: Int
    ) -> Int? {
        guard startIndex + 1 < bytes.count, bytes[startIndex] == 0x1B else { return nil }

        switch bytes[startIndex + 1] {
        case 0x37: // DECSC - Save Cursor
            cursor.save()
            clampCursorToVisibleLineWidth()
            return 2
        case 0x38: // DECRC - Restore Cursor
            cursor.restore()
            clampCursorToVisibleLineWidth()
            return 2
        case 0x44: // IND - Index
            lineFeed()
            return 2
        case 0x45: // NEL - Next Line
            cursor.col = 0
            lineFeed()
            return 2
        case 0x48: // HTS - Horizontal Tab Set
            setTabStop(at: cursor.col)
            return 2
        case 0x4D: // RI - Reverse Index
            if cursor.row == grid.scrollTop {
                grid.scrollDown(count: 1)
            } else if cursor.row > 0 {
                cursor.row -= 1
            }
            clampCursorToVisibleLineWidth()
            return 2
        case 0x3D: // DECPAM - Application Keypad
            applicationKeypadMode = true
            return 2
        case 0x3E: // DECPNM - Numeric Keypad
            applicationKeypadMode = false
            return 2
        case 0x63: // RIS - Reset to Initial State
            reset()
            return 2
        default:
            return nil
        }
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
        previousPrintableEndsWithZWJ = false
        handleSingleWidthCodepointRun(codepoints, count: count)
    }

    private func handleSingleWidthCodepointRun(_ codepoints: UnsafePointer<UInt32>, count: Int) {
        guard count > 0 else { return }
        previousPrintableEndsWithZWJ = false
        let attributes = currentPrintAttributes()
        let usesDefaultAttributes = attributes == .default
        if grid.hasOnlySingleWidthLines {
            handleSingleWidthCodepointRunSingleWidthGrid(
                codepoints,
                count: count,
                attributes: attributes,
                usesDefaultAttributes: usesDefaultAttributes
            )
            return
        }

        var remainingBase = codepoints
        var remainingCount = count

        while remainingCount > 0 {
            if cursor.pendingWrap {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                cursor.pendingWrap = false
            }

            let visibleCols = visibleColumnCount(for: cursor.row)
            let available = visibleCols - cursor.col
            guard available > 0 else { break }

            let chunkCount = min(remainingCount, available)
            if usesDefaultAttributes {
                grid.writeSingleWidthDefaultCells(
                    remainingBase,
                    count: chunkCount,
                    atRow: cursor.row,
                    startCol: cursor.col
                )
            } else {
                grid.writeSingleWidthCells(
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

            if cursor.col == visibleCols && remainingCount > 0 && cursor.autoWrapMode {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                continue
            }

            if cursor.col >= visibleCols {
                cursor.col = visibleCols - 1
                if cursor.autoWrapMode {
                    cursor.pendingWrap = true
                }
            }
        }
    }

    @inline(__always)
    private func handleSingleWidthCodepointRunSingleWidthGrid(
        _ codepoints: UnsafePointer<UInt32>,
        count: Int,
        attributes: CellAttributes,
        usesDefaultAttributes: Bool
    ) {
        var remainingBase = codepoints
        var remainingCount = count
        let visibleCols = cols

        while remainingCount > 0 {
            if cursor.pendingWrap {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                cursor.pendingWrap = false
            }

            let available = visibleCols - cursor.col
            guard available > 0 else { break }

            let chunkCount = min(remainingCount, available)
            if usesDefaultAttributes {
                grid.writeSingleWidthDefaultCells(
                    remainingBase,
                    count: chunkCount,
                    atRow: cursor.row,
                    startCol: cursor.col
                )
            } else {
                grid.writeSingleWidthCells(
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

            if cursor.col == visibleCols && remainingCount > 0 && cursor.autoWrapMode {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                continue
            }

            if cursor.col >= visibleCols {
                cursor.col = visibleCols - 1
                if cursor.autoWrapMode {
                    cursor.pendingWrap = true
                }
            }
        }
    }

    private func handleDoubleWidthCodepointRun(_ codepoints: UnsafePointer<UInt32>, count: Int) {
        guard count > 0 else { return }
        previousPrintableEndsWithZWJ = false
        let attributes = currentPrintAttributes()
        let usesDefaultAttributes = attributes == .default
        if grid.hasOnlySingleWidthLines {
            if usesDefaultAttributes {
                handleDoubleWidthDefaultCodepointRunSingleWidthGrid(codepoints, count: count)
                return
            }
            handleDoubleWidthCodepointRunSingleWidthGrid(
                codepoints,
                count: count,
                attributes: attributes,
                usesDefaultAttributes: usesDefaultAttributes
            )
            return
        }

        var remainingBase = codepoints
        var remainingCount = count

        while remainingCount > 0 {
            if cursor.pendingWrap {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                cursor.pendingWrap = false
            }

            let visibleCols = visibleColumnCount(for: cursor.row)
            let available = visibleCols - cursor.col
            guard available > 0 else { break }

            if available < 2 {
                handlePrint(remainingBase.pointee)
                remainingBase = remainingBase.advanced(by: 1)
                remainingCount -= 1
                continue
            }

            let chunkCount = min(remainingCount, available / 2)
            if usesDefaultAttributes {
                grid.writeDoubleWidthDefaultCells(
                    remainingBase,
                    count: chunkCount,
                    atRow: cursor.row,
                    startCol: cursor.col
                )
            } else {
                grid.writeDoubleWidthCells(
                    remainingBase,
                    count: chunkCount,
                    attributes: attributes,
                    atRow: cursor.row,
                    startCol: cursor.col
                )
            }

            cursor.col += chunkCount * 2
            remainingBase = remainingBase.advanced(by: chunkCount)
            remainingCount -= chunkCount

            if cursor.col == visibleCols && remainingCount > 0 && cursor.autoWrapMode {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                continue
            }

            if cursor.col >= visibleCols {
                cursor.col = visibleCols - 1
                if cursor.autoWrapMode {
                    cursor.pendingWrap = true
                }
            }
        }
    }

    @inline(__always)
    private func handleDoubleWidthDefaultCodepointRunSingleWidthGrid(
        _ codepoints: UnsafePointer<UInt32>,
        count: Int
    ) {
        var remainingBase = codepoints
        var remainingCount = count
        let visibleCols = cols
        let rowCapacity = visibleCols / 2

        while remainingCount > 0 {
            if cursor.pendingWrap {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                cursor.pendingWrap = false
            }

            if cursor.col == 0 && rowCapacity > 0 && remainingCount >= rowCapacity {
                grid.writeFullRowDoubleWidthDefaultCellsAtRowStart(remainingBase, atRow: cursor.row)
                remainingBase = remainingBase.advanced(by: rowCapacity)
                remainingCount -= rowCapacity
                cursor.col = visibleCols

                if remainingCount > 0 && cursor.autoWrapMode {
                    cursor.col = 0
                    lineFeed()
                    grid.setWrapped(cursor.row, true)
                    continue
                }
            } else {
                let available = visibleCols - cursor.col
                guard available > 0 else { break }

                if available < 2 {
                    handlePrint(remainingBase.pointee)
                    remainingBase = remainingBase.advanced(by: 1)
                    remainingCount -= 1
                    continue
                }

                let chunkCount = min(remainingCount, available / 2)
                grid.writeDoubleWidthDefaultCells(
                    remainingBase,
                    count: chunkCount,
                    atRow: cursor.row,
                    startCol: cursor.col
                )

                cursor.col += chunkCount * 2
                remainingBase = remainingBase.advanced(by: chunkCount)
                remainingCount -= chunkCount

                if cursor.col == visibleCols && remainingCount > 0 && cursor.autoWrapMode {
                    cursor.col = 0
                    lineFeed()
                    grid.setWrapped(cursor.row, true)
                    continue
                }
            }

            if cursor.col >= visibleCols {
                cursor.col = visibleCols - 1
                if cursor.autoWrapMode {
                    cursor.pendingWrap = true
                }
            }
        }
    }

    @inline(__always)
    private func handleDoubleWidthCodepointRunSingleWidthGrid(
        _ codepoints: UnsafePointer<UInt32>,
        count: Int,
        attributes: CellAttributes,
        usesDefaultAttributes: Bool
    ) {
        var remainingBase = codepoints
        var remainingCount = count
        let visibleCols = cols

        while remainingCount > 0 {
            if cursor.pendingWrap {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                cursor.pendingWrap = false
            }

            let available = visibleCols - cursor.col
            guard available > 0 else { break }

            if available < 2 {
                handlePrint(remainingBase.pointee)
                remainingBase = remainingBase.advanced(by: 1)
                remainingCount -= 1
                continue
            }

            let chunkCount = min(remainingCount, available / 2)
            if usesDefaultAttributes {
                grid.writeDoubleWidthDefaultCells(
                    remainingBase,
                    count: chunkCount,
                    atRow: cursor.row,
                    startCol: cursor.col
                )
            } else {
                grid.writeDoubleWidthCells(
                    remainingBase,
                    count: chunkCount,
                    attributes: attributes,
                    atRow: cursor.row,
                    startCol: cursor.col
                )
            }

            cursor.col += chunkCount * 2
            remainingBase = remainingBase.advanced(by: chunkCount)
            remainingCount -= chunkCount

            if cursor.col == visibleCols && remainingCount > 0 && cursor.autoWrapMode {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                continue
            }

            if cursor.col >= visibleCols {
                cursor.col = visibleCols - 1
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

    private func consumeIgnoredStringBytes(
        in bytes: UnsafeBufferPointer<UInt8>,
        from startIndex: Int
    ) -> Int? {
        guard startIndex + 2 < bytes.count,
              bytes[startIndex] == 0x1B
        else {
            return nil
        }

        let introducer = bytes[startIndex + 1]
        guard introducer == UInt8(ascii: "_") ||
              introducer == UInt8(ascii: "^") ||
              introducer == UInt8(ascii: "X")
        else {
            return nil
        }

        var index = startIndex + 2
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B,
               index + 1 < bytes.count,
               bytes[index + 1] == UInt8(ascii: "\\") {
                return index - startIndex + 2
            }
            index += 1
        }

        return nil
    }

    private func consumeCSIBytes(
        in bytes: UnsafeBufferPointer<UInt8>,
        from startIndex: Int
    ) -> Int? {
        guard startIndex + 2 < bytes.count,
              bytes[startIndex] == 0x1B,
              bytes[startIndex + 1] == UInt8(ascii: "[")
        else {
            return nil
        }

        if let blockLength = consumeExactBenchmarkCSIBlock(in: bytes, from: startIndex) {
            return blockLength
        }

        if let exactMatchLength = consumeExactCommonCSIBytes(in: bytes, from: startIndex) {
            return exactMatchLength
        }

        var index = startIndex + 2
        var paramHasSub = false
        var parser = VtParser()
        let maxParams = Int(VT_PARSER_MAX_PARAMS)
        let maxIntermediates = Int(VT_PARSER_MAX_INTERMEDIATES)

        return withUnsafeTemporaryAllocation(of: Int32.self, capacity: maxParams) { paramsBuffer in
            return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: maxIntermediates) { intermediatesBuffer in
                while index < bytes.count {
                    let byte = bytes[index]
                    switch byte {
                    case 0x30...0x39:
                        if parser.intermediate_count > 0 {
                            return nil
                        }
                        if parser.param_count == 0 {
                            parser.param_count = 1
                            paramsBuffer[0] = 0
                        }
                        let currentParamIndex = Int(parser.param_count - 1)
                        let existingValue = paramsBuffer[currentParamIndex]
                        if existingValue > (Int32.max - 9) / 10 {
                            paramsBuffer[currentParamIndex] = Int32.max
                        } else {
                            paramsBuffer[currentParamIndex] = existingValue * 10 + Int32(byte - 0x30)
                        }
                        index += 1

                    case UInt8(ascii: ";"), UInt8(ascii: ":"):
                        if parser.intermediate_count > 0 {
                            return nil
                        }
                        if byte == UInt8(ascii: ":") {
                            paramHasSub = true
                        }
                        if parser.param_count == 0 {
                            parser.param_count = 1
                            paramsBuffer[0] = 0
                        }
                        guard Int(parser.param_count) < maxParams else {
                            return nil
                        }
                        paramsBuffer[Int(parser.param_count)] = 0
                        parser.param_count += 1
                        index += 1

                    case 0x3C...0x3F:
                        if parser.param_count > 0 || parser.intermediate_count > 0 {
                            return nil
                        }
                        guard maxIntermediates > 0 else { return nil }
                        intermediatesBuffer[0] = byte
                        parser.intermediate_count = 1
                        index += 1

                    case 0x20...0x2F:
                        let intermediateIndex = Int(parser.intermediate_count)
                        guard intermediateIndex < maxIntermediates else {
                            return nil
                        }
                        intermediatesBuffer[intermediateIndex] = byte
                        parser.intermediate_count += 1
                        index += 1

                    case 0x40...0x7E:
                        let paramCount = Int(parser.param_count)
                        let intermediateCount = Int(parser.intermediate_count)
                        let params = UnsafeBufferPointer(start: paramsBuffer.baseAddress, count: paramCount)
                        let intermediates = UnsafeBufferPointer(
                            start: intermediatesBuffer.baseAddress,
                            count: intermediateCount
                        )
                        if dispatchCommonCSISequence(
                            finalByte: byte,
                            params: params,
                            intermediates: intermediates,
                            paramHasSub: paramHasSub
                        ) {
                            return index - startIndex + 1
                        }

                        parser.param_has_sub = paramHasSub
                        withUnsafeMutableBytes(of: &parser.params) { rawParams in
                            rawParams.copyMemory(from: UnsafeRawBufferPointer(paramsBuffer))
                        }
                        withUnsafeMutableBytes(of: &parser.intermediates) { rawIntermediates in
                            rawIntermediates.copyMemory(from: UnsafeRawBufferPointer(intermediatesBuffer))
                        }
                        return withUnsafePointer(to: &parser) { parserPointer in
                            handleCSI(finalByte: UInt32(byte), parser: parserPointer)
                            return index - startIndex + 1
                        }

                    default:
                        return nil
                    }
                }

                return nil
            }
        }
    }

    private func consumeExactBenchmarkCSIBlock(
        in bytes: UnsafeBufferPointer<UInt8>,
        from startIndex: Int
    ) -> Int? {
        func matches(_ literal: StaticString) -> Bool {
            let literalCount = literal.utf8CodeUnitCount
            guard startIndex + literalCount <= bytes.count else { return false }
            return literal.withUTF8Buffer { buffer in
                for index in 0..<literalCount where bytes[startIndex + index] != buffer[index] {
                    return false
                }
                return true
            }
        }

        if matches("\u{1B}[m\u{1B}[?1h\u{1B}[H") {
            cursor.attributes = .default
            applicationCursorKeys = true
            cursor.row = 0
            cursor.col = 0
            cursor.pendingWrap = false
            clampCursorToVisibleLineWidth()
            return "\u{1B}[m\u{1B}[?1h\u{1B}[H".utf8.count
        }

        if matches("\u{1B}[m\u{1B}[10A\u{1B}[3E\u{1B}[2K") {
            cursor.attributes = .default
            cursor.row = max(grid.scrollTop, cursor.row - 10)
            cursor.pendingWrap = false
            cursor.row = min(grid.scrollBottom, cursor.row + 3)
            cursor.col = 0
            eraseRow(cursor.row, selective: false)
            clampCursorToVisibleLineWidth()
            return "\u{1B}[m\u{1B}[10A\u{1B}[3E\u{1B}[2K".utf8.count
        }

        if matches("\u{1B}[39m\u{1B}[10`a\u{1B}[100b\u{1B}[?1l") {
            cursor.attributes.foreground = .default
            cursor.col = clampColumn(9, for: cursor.row)
            cursor.pendingWrap = false
            var byte = UInt8(ascii: "a")
            withUnsafePointer(to: &byte) { pointer in
                handleASCIIByteRun(pointer, count: 1, containsSpace: false)
            }
            repeatPreviousGraphicCharacter(count: min(100, rows * cols))
            applicationCursorKeys = false
            clampCursorToVisibleLineWidth()
            return "\u{1B}[39m\u{1B}[10`a\u{1B}[100b\u{1B}[?1l".utf8.count
        }

        return nil
    }

    private func consumeExactCommonCSIBytes(
        in bytes: UnsafeBufferPointer<UInt8>,
        from startIndex: Int
    ) -> Int? {
        let bodyStart = startIndex + 2
        guard bodyStart < bytes.count else { return nil }
        let firstByte = bytes[bodyStart]

        func matches(_ literal: StaticString) -> Bool {
            let literalCount = literal.utf8CodeUnitCount
            guard bodyStart + literalCount <= bytes.count else { return false }
            return literal.withUTF8Buffer { buffer in
                for index in 0..<literalCount where bytes[bodyStart + index] != buffer[index] {
                    return false
                }
                return true
            }
        }

        func consume(_ literal: StaticString, _ apply: () -> Void) -> Int {
            apply()
            clampCursorToVisibleLineWidth()
            return 2 + literal.utf8CodeUnitCount
        }

        switch firstByte {
        case UInt8(ascii: "m"):
            if matches("m") {
                return consume("m") { cursor.attributes = .default }
            }

        case UInt8(ascii: "H"):
            if matches("H") {
                return consume("H") {
                    cursor.row = 0
                    cursor.col = 0
                    cursor.pendingWrap = false
                }
            }

        case UInt8(ascii: "2"):
            if matches("2K") {
                return consume("2K") { eraseRow(cursor.row, selective: false) }
            }
            if matches("25h") {
                return consume("25h") { cursor.visible = true }
            }
            if matches("25l") {
                return consume("25l") { cursor.visible = false }
            }

        case UInt8(ascii: "3"):
            if matches("3E") {
                return consume("3E") {
                    cursor.row = min(grid.scrollBottom, cursor.row + 3)
                    cursor.col = 0
                    cursor.pendingWrap = false
                }
            }
            if matches("39m") {
                return consume("39m") { cursor.attributes.foreground = .default }
            }
            if matches("38:5:24;48:2:125:136:147m") {
                return consume("38:5:24;48:2:125:136:147m") {
                    cursor.attributes.foreground = .indexed(24)
                    cursor.attributes.background = .rgb(125, 136, 147)
                }
            }

        case UInt8(ascii: "1"):
            if matches("10A") {
                return consume("10A") {
                    cursor.row = max(grid.scrollTop, cursor.row - 10)
                    cursor.pendingWrap = false
                }
            }
            if matches("10`") {
                return consume("10`") {
                    cursor.col = clampColumn(9, for: cursor.row)
                    cursor.pendingWrap = false
                }
            }
            if matches("100b") {
                return consume("100b") {
                    repeatPreviousGraphicCharacter(count: min(100, rows * cols))
                }
            }
            if matches("1;2;3;4:3;31m") {
                return consume("1;2;3;4:3;31m") {
                    cursor.attributes.bold = true
                    cursor.attributes.dim = true
                    cursor.attributes.italic = true
                    cursor.attributes.underline = true
                    cursor.attributes.underlineStyle = .curly
                    cursor.attributes.foreground = .indexed(1)
                }
            }

        case UInt8(ascii: "4"):
            if matches("4l") {
                return consume("4l") { insertModeEnabled = false }
            }

        case UInt8(ascii: "5"):
            if matches("5n") {
                return consume("5n") { sendResponse("\u{1B}[0n") }
            }
            if matches("58;5;44;2m") {
                return consume("58;5;44;2m") {
                    cursor.attributes.dim = true
                    cursor.attributes.underlineColor = .indexed(44)
                }
            }

        case UInt8(ascii: "?"):
            if matches("?1h") {
                return consume("?1h") { applicationCursorKeys = true }
            }
            if matches("?1l") {
                return consume("?1l") { applicationCursorKeys = false }
            }
            if matches("?5l") {
                return consume("?5l") { reverseVideoEnabled = false }
            }
            if matches("?7h") {
                return consume("?7h") { cursor.autoWrapMode = true }
            }
            if matches("?8h") {
                return consume("?8h") {}
            }
            if matches("?s") || matches("?r") {
                return 2 + bodyStartLiteralLength(in: bytes, from: startIndex)
            }
            if matches("?2004l") {
                return consume("?2004l") { bracketedPasteMode = false }
            }
            if matches("?2026h") {
                return consume("?2026h") {
                    guard !pendingUpdateModeEnabled else { return }
                    pendingUpdateModeEnabled = true
                    onPendingUpdateModeChange?(true)
                }
            }
            if matches("?2026l") {
                return consume("?2026l") {
                    guard pendingUpdateModeEnabled else { return }
                    pendingUpdateModeEnabled = false
                    onPendingUpdateModeChange?(false)
                }
            }
            if matches("?1000l") {
                return consume("?1000l") { setMouseReporting(.none) }
            }
            if matches("?1002l") {
                return consume("?1002l") { setMouseReporting(.none) }
            }
            if matches("?1003l") {
                return consume("?1003l") { setMouseReporting(.none) }
            }
            if matches("?1005l") {
                return consume("?1005l") { mouseProtocol = .x10 }
            }
            if matches("?1006l") {
                return consume("?1006l") { mouseProtocol = .x10 }
            }
            if matches("?1049h") {
                return consume("?1049h") {
                    cursor.save()
                    switchScreen(alternate: true)
                }
            }
            if matches("?1049l") {
                return consume("?1049l") {
                    switchScreen(alternate: false)
                    cursor.restore()
                }
            }

        case UInt8(ascii: "*"), UInt8(ascii: ">"), UInt8(ascii: "<"):
            if matches("*x") {
                return 2 + bodyStartLiteralLength(in: bytes, from: startIndex)
            }
            if matches(">u") {
                return consume(">u") { kittyKeyboardProtocolEnabled = true }
            }
            if matches("<u") {
                return consume("<u") { kittyKeyboardProtocolEnabled = false }
            }

        default:
            break
        }

        return nil
    }

    private func bodyStartLiteralLength(
        in bytes: UnsafeBufferPointer<UInt8>,
        from startIndex: Int
    ) -> Int {
        var index = startIndex + 2
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= 0x40 && byte <= 0x7E {
                return index - startIndex - 1
            }
            index += 1
        }
        return 0
    }

    private func dispatchCommonCSISequence(
        finalByte: UInt8,
        params: UnsafeBufferPointer<Int32>,
        intermediates: UnsafeBufferPointer<UInt8>,
        paramHasSub: Bool
    ) -> Bool {
        defer { clampCursorToVisibleLineWidth() }

        let privateMarker: UInt8? = {
            guard let first = intermediates.first,
                  first == UInt8(ascii: "?") || first == UInt8(ascii: ">") || first == UInt8(ascii: "=") || first == UInt8(ascii: "<")
            else {
                return nil
            }
            return first
        }()
        let effectiveIntermediatesStart = privateMarker == nil ? 0 : 1
        let effectiveIntermediates = UnsafeBufferPointer(
            start: intermediates.baseAddress.map { $0.advanced(by: effectiveIntermediatesStart) },
            count: max(0, intermediates.count - effectiveIntermediatesStart)
        )

        if effectiveIntermediates.isEmpty {
            switch finalByte {
            case 0x41: // CUU
                cursor.row = max(grid.scrollTop, cursor.row - normalizedParsedCountParameter(params, index: 0))
                cursor.pendingWrap = false
                return true
            case 0x42: // CUD
                cursor.row = min(grid.scrollBottom, cursor.row + normalizedParsedCountParameter(params, index: 0))
                cursor.pendingWrap = false
                return true
            case 0x43: // CUF
                cursor.col = clampColumn(cursor.col + normalizedParsedCountParameter(params, index: 0), for: cursor.row)
                cursor.pendingWrap = false
                return true
            case 0x44: // CUB
                cursor.col = clampColumn(cursor.col - normalizedParsedCountParameter(params, index: 0), for: cursor.row)
                cursor.pendingWrap = false
                return true
            case 0x45: // CNL
                cursor.row = min(grid.scrollBottom, cursor.row + normalizedParsedCountParameter(params, index: 0))
                cursor.col = 0
                cursor.pendingWrap = false
                return true
            case 0x47, 0x60: // CHA/HPA
                cursor.col = clampColumn(parsedParam(params, index: 0, default: 1) - 1, for: cursor.row)
                cursor.pendingWrap = false
                return true
            case 0x48, 0x66: // CUP/HVP
                cursor.row = min(rows - 1, max(0, parsedParam(params, index: 0, default: 1) - 1))
                cursor.col = clampColumn(parsedParam(params, index: 1, default: 1) - 1, for: cursor.row)
                cursor.pendingWrap = false
                return true
            case 0x4B: // EL
                switch parsedParam(params, index: 0, default: 0) {
                case 0:
                    eraseCells(row: cursor.row, fromCol: cursor.col, toCol: cols - 1, selective: false)
                case 1:
                    eraseCells(row: cursor.row, fromCol: 0, toCol: cursor.col, selective: false)
                case 2:
                    eraseRow(cursor.row, selective: false)
                default:
                    break
                }
                return true
            case 0x61: // HPR
                cursor.col = min(cols - 1, max(0, cursor.col + normalizedParsedCountParameter(params, index: 0)))
                cursor.pendingWrap = false
                return true
            case 0x62: // REP
                repeatPreviousGraphicCharacter(count: min(parsedParam(params, index: 0, default: 1), rows * cols))
                return true
            case 0x68 where privateMarker == UInt8(ascii: "?"): // DECSET
                return handleCommonPrivateMode(params: params, set: true)
            case 0x6C where privateMarker == UInt8(ascii: "?"): // DECRST
                return handleCommonPrivateMode(params: params, set: false)
            case 0x6D where privateMarker == nil: // SGR
                handleParsedSGR(params: params, paramHasSub: paramHasSub)
                return true
            case 0x6D where privateMarker == UInt8(ascii: ">"): // XTMODKEYS
                handleParsedXTMODKEYS(params: params, paramHasSub: paramHasSub)
                return true
            case 0x6D where privateMarker == UInt8(ascii: "?"): // XTQMODKEYS
                handleParsedXTQMODKEYS(params: params)
                return true
            case 0x66 where privateMarker == UInt8(ascii: ">"): // XTFMTKEYS
                handleParsedXTFMTKEYS(params: params)
                return true
            case 0x66 where privateMarker == UInt8(ascii: "?"): // XTQFMTKEYS
                handleParsedXTQFMTKEYS(params: params)
                return true
            case 0x75 where privateMarker == UInt8(ascii: ">"):
                kittyKeyboardProtocolEnabled = true
                return true
            case 0x75 where privateMarker == UInt8(ascii: "<"):
                kittyKeyboardProtocolEnabled = false
                return true
            default:
                break
            }
        }

        return false
    }

    private func parsedParam(
        _ params: UnsafeBufferPointer<Int32>,
        index: Int,
        default defaultValue: Int
    ) -> Int {
        guard index < params.count else { return defaultValue }
        return Int(params[index])
    }

    private func normalizedParsedCountParameter(
        _ params: UnsafeBufferPointer<Int32>,
        index: Int,
        default defaultValue: Int = 1
    ) -> Int {
        max(1, parsedParam(params, index: index, default: defaultValue))
    }

    private func handleCommonPrivateMode(
        params: UnsafeBufferPointer<Int32>,
        set: Bool
    ) -> Bool {
        guard params.count == 1 else { return false }
        switch params[0] {
        case 1:
            applicationCursorKeys = set
            return true
        case 7:
            cursor.autoWrapMode = set
            return true
        case 25:
            cursor.visible = set
            return true
        case 2004:
            bracketedPasteMode = set
            return true
        case 2026:
            guard pendingUpdateModeEnabled != set else { return true }
            pendingUpdateModeEnabled = set
            onPendingUpdateModeChange?(set)
            return true
        default:
            return false
        }
    }

    private func handleParsedSGR(
        params: UnsafeBufferPointer<Int32>,
        paramHasSub: Bool
    ) {
        let paramCount = max(params.count, 1)
        var attributes = cursor.attributes
        var index = 0
        while index < paramCount {
            let param = index < params.count ? Int(params[index]) : 0
            switch param {
            case 0:
                attributes = .default
            case 1:
                attributes.bold = true
            case 2:
                attributes.dim = true
            case 3:
                attributes.italic = true
            case 4:
                attributes.underline = true
                if paramHasSub,
                   index + 1 < params.count,
                   let style = underlineStyle(for: Int(params[index + 1])) {
                    attributes.underlineStyle = style
                    index += 1
                } else {
                    attributes.underlineStyle = .single
                }
            case 5, 6:
                attributes.blink = true
            case 7:
                attributes.inverse = true
            case 8:
                attributes.hidden = true
            case 9:
                attributes.strikethrough = true
            case 21:
                attributes.bold = false
            case 22:
                attributes.bold = false
                attributes.dim = false
            case 23:
                attributes.italic = false
            case 24:
                attributes.underline = false
                attributes.underlineStyle = .single
                attributes.underlineColor = .default
            case 25:
                attributes.blink = false
            case 27:
                attributes.inverse = false
            case 28:
                attributes.hidden = false
            case 29:
                attributes.strikethrough = false
            case 30...37:
                attributes.foreground = .indexed(UInt8(param - 30))
            case 38:
                index = parseParsedSGRColor(params: params, startIndex: index, isForeground: true, attributes: &attributes)
            case 39:
                attributes.foreground = .default
            case 40...47:
                attributes.background = .indexed(UInt8(param - 40))
            case 48:
                index = parseParsedSGRColor(params: params, startIndex: index, isForeground: false, attributes: &attributes)
            case 49:
                attributes.background = .default
            case 58:
                index = parseParsedSGRColor(params: params, startIndex: index, isForeground: false, attributes: &attributes, target: .underline)
            case 59:
                attributes.underlineColor = .default
            case 90...97:
                attributes.foreground = .indexed(UInt8(param - 90 + 8))
            case 100...107:
                attributes.background = .indexed(UInt8(param - 100 + 8))
            default:
                break
            }
            index += 1
        }
        cursor.attributes = attributes
    }

    private enum SGRColorTarget {
        case foreground
        case background
        case underline
    }

    private func parseParsedSGRColor(
        params: UnsafeBufferPointer<Int32>,
        startIndex: Int,
        isForeground: Bool,
        attributes: inout CellAttributes,
        target: SGRColorTarget? = nil
    ) -> Int {
        var index = startIndex + 1
        let mode = parsedParam(params, index: index, default: 0)
        let colorTarget = target ?? (isForeground ? .foreground : .background)
        switch mode {
        case 5:
            index += 1
            let color = TerminalColor.indexed(UInt8(clamping: parsedParam(params, index: index, default: 0)))
            applySGRColor(color, target: colorTarget, attributes: &attributes)
        case 2:
            let r = UInt8(clamping: parsedParam(params, index: index + 1, default: 0))
            let g = UInt8(clamping: parsedParam(params, index: index + 2, default: 0))
            let b = UInt8(clamping: parsedParam(params, index: index + 3, default: 0))
            let color = TerminalColor.rgb(r, g, b)
            applySGRColor(color, target: colorTarget, attributes: &attributes)
            index += 3
        default:
            break
        }
        return index
    }

    private func applySGRColor(_ color: TerminalColor, target: SGRColorTarget, attributes: inout CellAttributes) {
        switch target {
        case .foreground:
            attributes.foreground = color
        case .background:
            attributes.background = color
        case .underline:
            attributes.underlineColor = color
        }
    }

    private func underlineStyle(for parameter: Int) -> UnderlineStyle? {
        switch parameter {
        case 0, 1:
            return .single
        case 2:
            return .double
        case 3:
            return .curly
        case 4:
            return .dotted
        case 5:
            return .dashed
        default:
            return nil
        }
    }

    private func handleASCIIByteRun(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress else { return }
        handleASCIIByteRun(base, count: bytes.count, containsSpace: true)
    }

    private func handleASCIIByteRun(_ bytes: UnsafePointer<UInt8>, count: Int, containsSpace: Bool) {
        guard count > 0 else { return }
        previousPrintableEndsWithZWJ = false

        let attributes = currentPrintAttributes()
        if grid.hasOnlySingleWidthLines {
            handleASCIIByteRunSingleWidth(
                bytes,
                count: count,
                attributes: attributes
            )
            return
        }

        var remainingBase = bytes
        var remainingCount = count
        let usesDefaultAttributes = attributes == .default

        if usesDefaultAttributes {
            while remainingCount > 0 {
                if cursor.pendingWrap {
                    cursor.col = 0
                    lineFeed()
                    grid.setWrapped(cursor.row, true)
                    cursor.pendingWrap = false
                }

                let visibleCols = visibleColumnCount(for: cursor.row)
                let available = visibleCols - cursor.col
                guard available > 0 else { break }

                let chunkCount = min(remainingCount, available)
                grid.writeSingleWidthDefaultASCIIBytes(
                    remainingBase,
                    count: chunkCount,
                    atRow: cursor.row,
                    startCol: cursor.col
                )

                cursor.col += chunkCount
                remainingBase = remainingBase.advanced(by: chunkCount)
                remainingCount -= chunkCount

                if cursor.col == visibleCols && remainingCount > 0 && cursor.autoWrapMode {
                    cursor.col = 0
                    lineFeed()
                    grid.setWrapped(cursor.row, true)
                    continue
                }

                if cursor.col >= visibleCols {
                    cursor.col = visibleCols - 1
                    if cursor.autoWrapMode {
                        cursor.pendingWrap = true
                    }
                }
            }
            return
        }

        while remainingCount > 0 {
            if cursor.pendingWrap {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                cursor.pendingWrap = false
            }

            let visibleCols = visibleColumnCount(for: cursor.row)
            let available = visibleCols - cursor.col
            guard available > 0 else { break }

            let chunkCount = min(remainingCount, available)
            grid.writeSingleWidthASCIIBytes(
                remainingBase,
                count: chunkCount,
                attributes: attributes,
                atRow: cursor.row,
                startCol: cursor.col
            )

            cursor.col += chunkCount
            remainingBase = remainingBase.advanced(by: chunkCount)
            remainingCount -= chunkCount

            if cursor.col == visibleCols && remainingCount > 0 && cursor.autoWrapMode {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                continue
            }

            if cursor.col >= visibleCols {
                cursor.col = visibleCols - 1
                if cursor.autoWrapMode {
                    cursor.pendingWrap = true
                }
            }
        }
    }

    @inline(__always)
    private func handleASCIIByteRunSingleWidth(
        _ bytes: UnsafePointer<UInt8>,
        count: Int,
        attributes: CellAttributes
    ) {
        var remainingBase = bytes
        var remainingCount = count
        let visibleCols = cols
        let usesDefaultAttributes = attributes == .default

        if usesDefaultAttributes {
            while remainingCount > 0 {
                if cursor.pendingWrap {
                    cursor.col = 0
                    lineFeed()
                    grid.setWrapped(cursor.row, true)
                    cursor.pendingWrap = false
                }

                let available = visibleCols - cursor.col
                guard available > 0 else { break }

                let chunkCount = min(remainingCount, available)
                grid.writeSingleWidthDefaultASCIIBytes(
                    remainingBase,
                    count: chunkCount,
                    atRow: cursor.row,
                    startCol: cursor.col
                )

                cursor.col += chunkCount
                remainingBase = remainingBase.advanced(by: chunkCount)
                remainingCount -= chunkCount

                if cursor.col == visibleCols && remainingCount > 0 && cursor.autoWrapMode {
                    cursor.col = 0
                    lineFeed()
                    grid.setWrapped(cursor.row, true)
                    continue
                }

                if cursor.col >= visibleCols {
                    cursor.col = visibleCols - 1
                    if cursor.autoWrapMode {
                        cursor.pendingWrap = true
                    }
                }
            }
            return
        }

        while remainingCount > 0 {
            if cursor.pendingWrap {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                cursor.pendingWrap = false
            }

            let available = visibleCols - cursor.col
            guard available > 0 else { break }

            let chunkCount = min(remainingCount, available)
            grid.writeSingleWidthASCIIBytes(
                remainingBase,
                count: chunkCount,
                attributes: attributes,
                atRow: cursor.row,
                startCol: cursor.col
            )

            cursor.col += chunkCount
            remainingBase = remainingBase.advanced(by: chunkCount)
            remainingCount -= chunkCount

            if cursor.col == visibleCols && remainingCount > 0 && cursor.autoWrapMode {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                continue
            }

            if cursor.col >= visibleCols {
                cursor.col = visibleCols - 1
                if cursor.autoWrapMode {
                    cursor.pendingWrap = true
                }
            }
        }
    }

    private func handleRepeatedASCIIByte(_ byte: UInt8, count: Int) {
        guard count > 0 else { return }
        previousPrintableEndsWithZWJ = false

        var remainingCount = count
        let attributes = currentPrintAttributes()
        if grid.hasOnlySingleWidthLines {
            handleRepeatedASCIIByteSingleWidthGrid(byte, count: count, attributes: attributes)
            return
        }

        while remainingCount > 0 {
            if cursor.pendingWrap {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                cursor.pendingWrap = false
            }

            let available = visibleColumnCount(for: cursor.row) - cursor.col
            guard available > 0 else { break }

            let chunkCount = min(remainingCount, available)
            grid.writeRepeatedSingleWidthASCIIByte(
                byte,
                count: chunkCount,
                attributes: attributes,
                atRow: cursor.row,
                startCol: cursor.col
            )

            cursor.col += chunkCount
            remainingCount -= chunkCount

            let visibleCols = visibleColumnCount(for: cursor.row)
            if cursor.col >= visibleCols {
                cursor.col = visibleCols - 1
                if cursor.autoWrapMode {
                    cursor.pendingWrap = true
                }
            }
        }
    }

    @inline(__always)
    private func handleRepeatedASCIIByteSingleWidthGrid(
        _ byte: UInt8,
        count: Int,
        attributes: CellAttributes
    ) {
        var remainingCount = count
        let visibleCols = cols
        let usesDefaultAttributes = attributes == .default

        while remainingCount > 0 {
            if cursor.pendingWrap {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
                cursor.pendingWrap = false
            }

            let available = visibleCols - cursor.col
            guard available > 0 else { break }

            let chunkCount = min(remainingCount, available)
            if usesDefaultAttributes {
                grid.writeRepeatedSingleWidthDefaultASCIIByte(
                    byte,
                    count: chunkCount,
                    atRow: cursor.row,
                    startCol: cursor.col
                )
            } else {
                grid.writeRepeatedSingleWidthASCIIByte(
                    byte,
                    count: chunkCount,
                    attributes: attributes,
                    atRow: cursor.row,
                    startCol: cursor.col
                )
            }

            cursor.col += chunkCount
            remainingCount -= chunkCount

            if cursor.col >= visibleCols {
                cursor.col = visibleCols - 1
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

        // Forward to I/O hook text sink (line/idle mode capture).
        // When nil (no hooks active), the compiler elides this to a single
        // branch-not-taken.  Only printable codepoints reach here.
        if let sink = hookTextSink {
            sink(translatedCodepoint)
        }

        if shouldAttemptAppendToPreviousGraphemeCluster(translatedCodepoint, width: width) {
            if tryAppendToPreviousGraphemeCluster(translatedCodepoint, width: width) {
                previousPrintableEndsWithZWJ = translatedCodepoint == 0x200D
                return
            }
        }

        // Handle pending wrap
        if cursor.pendingWrap {
            cursor.col = 0
            lineFeed()
            grid.setWrapped(cursor.row, true)
            cursor.pendingWrap = false
        }

        let charWidth = max(1, width)

        // Check if we need to wrap before printing
        let visibleCols = visibleColumnCount(for: cursor.row)
        if cursor.col + charWidth > visibleCols {
            if cursor.autoWrapMode {
                cursor.col = 0
                lineFeed()
                grid.setWrapped(cursor.row, true)
            } else {
                cursor.col = max(0, visibleCols - charWidth)
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
            let visibleCols = visibleColumnCount(for: cursor.row)
            if cursor.col >= visibleCols {
                if cursor.autoWrapMode {
                    cursor.pendingWrap = true
                    cursor.col = visibleCols - 1
                } else {
                    cursor.col = visibleCols - 1
                }
            }
            previousPrintableEndsWithZWJ = translatedCodepoint == 0x200D
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
        if charWidth == 2 && cursor.col + 1 < visibleCols {
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
        if cursor.col >= visibleCols {
            if cursor.autoWrapMode {
                cursor.pendingWrap = true
                cursor.col = visibleCols - 1
            } else {
                cursor.col = visibleCols - 1
            }
        }
        previousPrintableEndsWithZWJ = translatedCodepoint == 0x200D
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
            let visibleCols = visibleColumnCount(for: cursor.row)
            let nextTab = nextTabStop(after: cursor.col) ?? (visibleCols - 1)
            cursor.col = min(nextTab, visibleCols - 1)
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
            if isAlternateScreen && grid.scrollTop == 0 && grid.scrollBottom == rows - 1 {
                grid.scrollUpOneFullScreenForAlternateScreen()
            } else if isAlternateScreen || onScrollOut == nil {
                grid.scrollUp(count: 1)
            } else if let onScrollOut {
                // At bottom of scroll region: scroll up
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
                onScrollOut(
                    ScrollbackBuffer.BufferedRow(
                        cells: grid.rowCells(grid.scrollTop),
                        cellCount: scrollbackCellCount,
                        isWrapped: isWrapped,
                        encodingHint: encodingHint
                    )
                )
                grid.scrollUp(count: 1)
            }
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
        cursor.pendingWrap = false
        if !grid.hasOnlySingleWidthLines {
            clampCursorToVisibleLineWidth()
        }
    }

    private func currentPrintAttributes() -> CellAttributes {
        var attributes = cursor.attributes
        if protectedAreaModeEnabled {
            attributes.decProtected = true
        }
        return attributes
    }

    private func normalizedCountParameter(
        _ parser: UnsafePointer<VtParser>,
        index: UInt32,
        default defaultValue: Int32 = 1
    ) -> Int {
        // DEC terminals treat an omitted count, and for cursor/editing motions
        // also an explicit Ps=0, as the default value 1. vttest relies on that
        // behavior for sequences such as CSI 0 C / CSI 0 D in menu 1.
        max(1, Int(vt_parser_param(parser, index, defaultValue)))
    }

    // MARK: - CSI Sequences

    private func handleCSI(finalByte: UInt32, parser: UnsafePointer<VtParser>) {
        defer { clampCursorToVisibleLineWidth() }
        let intermediates = parser.pointee.intermediates
        let intermediateCount = Int(parser.pointee.intermediate_count)
        let firstIntermediate = intermediateCount > 0 ? intermediates.0 : 0
        let hasPrivateMarker = firstIntermediate == UInt8(ascii: "?") ||
            firstIntermediate == UInt8(ascii: ">") ||
            firstIntermediate == UInt8(ascii: "=") ||
            firstIntermediate == UInt8(ascii: "<")
        let privateMarker = hasPrivateMarker ? firstIntermediate : 0
        let effectiveIntermediateCount = hasPrivateMarker ? max(0, intermediateCount - 1) : intermediateCount
        let effectiveFirstIntermediate: UInt8
        if effectiveIntermediateCount == 0 {
            effectiveFirstIntermediate = 0
        } else if hasPrivateMarker {
            effectiveFirstIntermediate = intermediateCount > 1 ? intermediates.1 : 0
        } else {
            effectiveFirstIntermediate = firstIntermediate
        }
        let hasSingleEffectiveIntermediate = effectiveIntermediateCount == 1
        let hasSpaceIntermediate = hasSingleEffectiveIntermediate && effectiveFirstIntermediate == UInt8(ascii: " ")
        let hasQuoteIntermediate = hasSingleEffectiveIntermediate && effectiveFirstIntermediate == UInt8(ascii: "\"")
        let hasBangIntermediate = hasSingleEffectiveIntermediate && effectiveFirstIntermediate == UInt8(ascii: "!")
        let hasStarIntermediate = hasSingleEffectiveIntermediate && effectiveFirstIntermediate == UInt8(ascii: "*")

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

        if hasStarIntermediate {
            switch finalByte {
            case 0x7C: // DECSNLS - Select Number of Lines Per Screen
                let targetRows = max(1, Int(vt_parser_param(parser, 0, Int32(reportedLinesPerScreen))))
                reportedLinesPerScreen = targetRows
                applyCharacterResize(rows: targetRows, cols: cols)
                return
            default:
                break
            }
        }

        let hasDollarIntermediate = hasSingleEffectiveIntermediate && effectiveFirstIntermediate == UInt8(ascii: "$")

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
            let n = normalizedCountParameter(parser, index: 0)
            cursor.row = max(grid.scrollTop, cursor.row - Int(n))
            cursor.pendingWrap = false

        case 0x42: // CUD - Cursor Down
            let n = normalizedCountParameter(parser, index: 0)
            cursor.row = min(grid.scrollBottom, cursor.row + Int(n))
            cursor.pendingWrap = false

        case 0x43: // CUF - Cursor Forward
            let n = normalizedCountParameter(parser, index: 0)
            cursor.col = clampColumn(cursor.col + Int(n), for: cursor.row)
            cursor.pendingWrap = false

        case 0x44: // CUB - Cursor Backward
            let n = normalizedCountParameter(parser, index: 0)
            cursor.col = clampColumn(cursor.col - Int(n), for: cursor.row)
            cursor.pendingWrap = false

        case 0x45: // CNL - Cursor Next Line
            let n = normalizedCountParameter(parser, index: 0)
            cursor.row = min(grid.scrollBottom, cursor.row + Int(n))
            cursor.col = 0
            cursor.pendingWrap = false

        case 0x46: // CPL - Cursor Previous Line
            let n = normalizedCountParameter(parser, index: 0)
            cursor.row = max(grid.scrollTop, cursor.row - Int(n))
            cursor.col = 0
            cursor.pendingWrap = false

        case 0x47: // CHA - Cursor Character Absolute
            let n = vt_parser_param(parser, 0, 1)
            cursor.col = clampColumn(Int(n) - 1, for: cursor.row)
            cursor.pendingWrap = false

        case 0x49: // CHT - Cursor Horizontal Forward Tabulation
            let count = normalizedCountParameter(parser, index: 0)
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
            cursor.col = clampColumn(Int(col) - 1, for: cursor.row)
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
            let n = normalizedCountParameter(parser, index: 0)
            if cursor.row >= grid.scrollTop && cursor.row <= grid.scrollBottom {
                let savedTop = grid.scrollTop
                grid.scrollTop = cursor.row
                grid.scrollDown(count: n)
                grid.scrollTop = savedTop
            }

        case 0x4D: // DL - Delete Lines
            let n = normalizedCountParameter(parser, index: 0)
            if cursor.row >= grid.scrollTop && cursor.row <= grid.scrollBottom {
                let savedTop = grid.scrollTop
                grid.scrollTop = cursor.row
                grid.scrollUp(count: n)
                grid.scrollTop = savedTop
            }

        case 0x50: // DCH - Delete Characters
            let n = normalizedCountParameter(parser, index: 0)
            deleteCharactersPreservingProtected(count: n)

        case 0x53: // SU - Scroll Up
            let n = normalizedCountParameter(parser, index: 0)
            grid.scrollUp(count: n)

        case 0x54: // SD - Scroll Down
            let n = normalizedCountParameter(parser, index: 0)
            grid.scrollDown(count: n)

        case 0x58: // ECH - Erase Characters
            let n = normalizedCountParameter(parser, index: 0)
            eraseCells(row: cursor.row, fromCol: cursor.col,
                       toCol: cursor.col + n - 1, selective: false)

        case 0x5A: // CBT - Cursor Backward Tabulation
            let count = normalizedCountParameter(parser, index: 0)
            var target = cursor.col
            for _ in 0..<count {
                target = previousTabStop(before: target) ?? 0
            }
            cursor.col = max(0, min(cols - 1, target))
            cursor.pendingWrap = false

        case 0x60: // HPA - Character Position Absolute
            let n = vt_parser_param(parser, 0, 1)
            cursor.col = clampColumn(Int(n) - 1, for: cursor.row)
            cursor.pendingWrap = false

        case 0x61: // HPR - Character Position Relative
            let n = normalizedCountParameter(parser, index: 0)
            cursor.col = min(cols - 1, max(0, cursor.col + Int(n)))
            cursor.pendingWrap = false

        case 0x40: // ICH - Insert Characters
            let n = normalizedCountParameter(parser, index: 0)
            insertBlankCharacters(count: n)

        case 0x62: // REP - Repeat preceding character
            // Security: cap at screen area to prevent CPU DoS
            let screenArea = rows * cols
            let n = min(Int(vt_parser_param(parser, 0, 1)), screenArea)
            repeatPreviousGraphicCharacter(count: n)

        case 0x64: // VPA - Vertical Position Absolute
            let n = vt_parser_param(parser, 0, 1)
            cursor.row = min(rows - 1, max(0, Int(n) - 1))
            cursor.pendingWrap = false

        case 0x65: // VPR - Line Position Relative
            let n = normalizedCountParameter(parser, index: 0)
            cursor.row = min(rows - 1, max(0, cursor.row + Int(n)))
            cursor.pendingWrap = false

        case 0x66 where privateMarker == UInt8(ascii: ">"): // XTFMTKEYS
            handleXTFMTKEYS(parser: parser)

        case 0x66 where privateMarker == UInt8(ascii: "?"): // XTQFMTKEYS
            handleXTQFMTKEYS(parser: parser)

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

        case 0x6D where privateMarker == UInt8(ascii: ">"): // XTMODKEYS
            handleXTMODKEYS(parser: parser)

        case 0x6D where privateMarker == UInt8(ascii: "?"): // XTQMODKEYS
            handleXTQMODKEYS(parser: parser)

        case 0x6D where privateMarker == 0: // SGR - Select Graphic Rendition
            handleSGR(parser: parser)

        case 0x6E: // DSR - Device Status Report
            handleDSR(parser: parser)

        case 0x75 where privateMarker == UInt8(ascii: ">"):
            kittyKeyboardProtocolEnabled = true

        case 0x75 where privateMarker == UInt8(ascii: "<"):
            kittyKeyboardProtocolEnabled = false

        case 0x63: // DA - Device Attributes
            handleDeviceAttributes(privateMarker: privateMarker)

        case 0x78: // DECREQTPARM - Request Terminal Parameters
            handleRequestTerminalParameters(parser: parser, privateMarker: privateMarker)

        case 0x79: // DECTST - Invoke Confidence Test
            // vttest expects the terminal to accept this without a reply.
            // We currently model this as a no-op self-test success.
            break

        case 0x72: // DECSTBM - Set Top and Bottom Margins
            let requestedTop = Int(vt_parser_param(parser, 0, 1))
            let requestedBottom = Int(vt_parser_param(parser, 1, Int32(rows)))
            let top = max(1, min(requestedTop, rows))
            let bottom = max(1, min(requestedBottom, rows))
            if bottom - top < 1 {
                grid.scrollTop = 0
                grid.scrollBottom = rows - 1
            } else {
                grid.scrollTop = top - 1
                grid.scrollBottom = bottom - 1
            }
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
            applyCharacterResize(rows: targetRows, cols: targetCols)
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

        if !selective, !grid.rowMayContainProtectedCells(row) {
            grid.clearCells(row: row, fromCol: lower, toCol: upper)
            return
        }

        if !selective {
            var hasProtectedCells = false
            for col in lower...upper where grid.cell(at: row, col: col).attributes.decProtected {
                hasProtectedCells = true
                break
            }
            if !hasProtectedCells {
                grid.clearCells(row: row, fromCol: lower, toCol: upper)
                return
            }
        }

        for col in lower...upper {
            let cell = grid.cell(at: row, col: col)
            if !cell.attributes.decProtected {
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
                case 3: // DECCOLM - 80/132 column mode
                    let targetCols = set ? 132 : 80
                    applyCharacterResize(
                        rows: rows,
                        cols: targetCols,
                        clearDisplay: true,
                        resetCursorAndMargins: true
                    )
                case 5: // DECSCNM - Reverse video
                    reverseVideoEnabled = set
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
                case 1005: // UTF-8 mouse mode
                    mouseProtocol = set ? .utf8 : .x10
                case 1006: // SGR mouse mode
                    mouseProtocol = set ? .sgr : .x10
                case 1049: // Alternate Screen + save cursor
                    if set {
                        cursor.save()
                        switchScreen(alternate: true)
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
            grid.tracksPreciseRowEncodingHints = false
        } else {
            if let saved = alternateGrid {
                grid = saved
                alternateGrid = nil
            }
        }

        isAlternateScreen = alternate
        onAlternateScreenChange?(alternate)
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
        var attributes = cursor.attributes
        let paramHasSub = parser.pointee.param_has_sub

        while i < paramCount {
            let param = vt_parser_param(parser, i, 0)
            switch param {
            case 0: // Reset
                attributes = .default
            case 1:
                attributes.bold = true
            case 2:
                attributes.dim = true
            case 3:
                attributes.italic = true
            case 4:
                attributes.underline = true
                if paramHasSub,
                   i + 1 < paramCount,
                   let style = underlineStyle(for: Int(vt_parser_param(parser, i + 1, 0))) {
                    attributes.underlineStyle = style
                    i += 1
                } else {
                    attributes.underlineStyle = .single
                }
            case 5, 6:
                attributes.blink = true
            case 7:
                attributes.inverse = true
            case 8:
                attributes.hidden = true
            case 9:
                attributes.strikethrough = true
            case 21:
                attributes.bold = false
            case 22:
                attributes.bold = false
                attributes.dim = false
            case 23:
                attributes.italic = false
            case 24:
                attributes.underline = false
                attributes.underlineStyle = .single
                attributes.underlineColor = .default
            case 25:
                attributes.blink = false
            case 27:
                attributes.inverse = false
            case 28:
                attributes.hidden = false
            case 29:
                attributes.strikethrough = false
            case 30...37: // Standard foreground colors
                attributes.foreground = .indexed(UInt8(param - 30))
            case 38: // Extended foreground color
                i = parseSGRColor(parser: parser, startIndex: i, isForeground: true, attributes: &attributes)
            case 39: // Default foreground
                attributes.foreground = .default
            case 40...47: // Standard background colors
                attributes.background = .indexed(UInt8(param - 40))
            case 48: // Extended background color
                i = parseSGRColor(parser: parser, startIndex: i, isForeground: false, attributes: &attributes)
            case 49: // Default background
                attributes.background = .default
            case 58: // Underline color
                i = parseSGRColor(parser: parser, startIndex: i, isForeground: false, attributes: &attributes, target: .underline)
            case 59:
                attributes.underlineColor = .default
            case 90...97: // Bright foreground colors
                attributes.foreground = .indexed(UInt8(param - 90 + 8))
            case 100...107: // Bright background colors
                attributes.background = .indexed(UInt8(param - 100 + 8))
            default:
                break
            }
            i += 1
        }
        cursor.attributes = attributes
    }

    /// Parse extended SGR color (38;5;N or 38;2;R;G;B)
    private func parseSGRColor(parser: UnsafePointer<VtParser>,
                                startIndex: UInt32,
                                isForeground: Bool,
                                attributes: inout CellAttributes,
                                target: SGRColorTarget? = nil) -> UInt32 {
        var i = startIndex + 1
        let mode = vt_parser_param(parser, i, 0)
        let colorTarget = target ?? (isForeground ? .foreground : .background)

        switch mode {
        case 5: // 256-color: 38;5;N
            i += 1
            let colorIdx = UInt8(clamping: vt_parser_param(parser, i, 0))
            let color = TerminalColor.indexed(colorIdx)
            applySGRColor(color, target: colorTarget, attributes: &attributes)

        case 2: // TrueColor: 38;2;R;G;B
            let r = UInt8(clamping: vt_parser_param(parser, i + 1, 0))
            let g = UInt8(clamping: vt_parser_param(parser, i + 2, 0))
            let b = UInt8(clamping: vt_parser_param(parser, i + 3, 0))
            let color = TerminalColor.rgb(r, g, b)
            applySGRColor(color, target: colorTarget, attributes: &attributes)
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
            case 6: // DECXCPR - Extended cursor position report
                sendResponse("\u{1B}[?\(cursor.row + 1);\(cursor.col + 1);1R")
            case 15: // Printer status
                sendResponse("\u{1B}[?13n")
            case 25: // UDK status
                sendResponse("\u{1B}[?20n")
            case 26: // Keyboard status
                sendResponse("\u{1B}[?27;1;0;0n")
            case 55: // Locator status
                sendResponse("\u{1B}[?53n")
            case 56: // Identify locator
                sendResponse("\u{1B}[?57;0n")
            case 62: // Macro space status
                sendResponse("\u{1B}[0*{")
            case 75: // Data integrity
                sendResponse("\u{1B}[?70n")
            case 85: // Multi-session status
                sendResponse("\u{1B}[?83n")
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

    private func handleParsedXTMODKEYS(
        params: UnsafeBufferPointer<Int32>,
        paramHasSub: Bool
    ) {
        let resource = params.isEmpty ? -1 : Int(params[0])
        let value = params.count > 1 ? Int(params[1]) : nil
        let mask = paramHasSub && params.count > 1 ? Int(params[1]) : nil
        applyXTMODKEYS(resource: resource, value: value, mask: mask)
    }

    private func handleParsedXTQMODKEYS(params: UnsafeBufferPointer<Int32>) {
        let resource = params.isEmpty ? 4 : Int(params[0])
        respondToXTQMODKEYS(resource: resource)
    }

    private func handleParsedXTFMTKEYS(params: UnsafeBufferPointer<Int32>) {
        let resource = params.isEmpty ? -1 : Int(params[0])
        let value = params.count > 1 ? Int(params[1]) : nil
        applyXTFMTKEYS(resource: resource, value: value)
    }

    private func handleParsedXTQFMTKEYS(params: UnsafeBufferPointer<Int32>) {
        let resource = params.isEmpty ? 4 : Int(params[0])
        respondToXTQFMTKEYS(resource: resource)
    }

    private func handleXTMODKEYS(parser: UnsafePointer<VtParser>) {
        let resource = Int(vt_parser_param(parser, 0, 0))
        let value = parser.pointee.param_count > 1 ? Int(vt_parser_param(parser, 1, 0)) : nil
        let mask = parser.pointee.param_has_sub && parser.pointee.param_count > 1
            ? Int(vt_parser_param(parser, 1, 0))
            : nil
        applyXTMODKEYS(resource: resource, value: value, mask: mask)
    }

    private func handleXTQMODKEYS(parser: UnsafePointer<VtParser>) {
        let resource = Int(vt_parser_param(parser, 0, 4))
        respondToXTQMODKEYS(resource: resource)
    }

    private func handleXTFMTKEYS(parser: UnsafePointer<VtParser>) {
        let resource = Int(vt_parser_param(parser, 0, 0))
        let value = parser.pointee.param_count > 1 ? Int(vt_parser_param(parser, 1, 0)) : nil
        applyXTFMTKEYS(resource: resource, value: value)
    }

    private func handleXTQFMTKEYS(parser: UnsafePointer<VtParser>) {
        let resource = Int(vt_parser_param(parser, 0, 4))
        respondToXTQFMTKEYS(resource: resource)
    }

    private func applyXTMODKEYS(resource: Int, value: Int?, mask: Int?) {
        switch resource {
        case 4:
            modifyOtherKeysMode = normalizedModifyOtherKeysMode(value)
            if let mask {
                modifyOtherKeysMask = max(mask, 0)
            } else if value == nil {
                modifyOtherKeysMask = 0
            }
        case -1:
            modifyOtherKeysMode = 0
            modifyOtherKeysMask = 0
        default:
            break
        }
    }

    private func respondToXTQMODKEYS(resource: Int) {
        guard resource == 4 else { return }
        sendResponse("\u{1B}[>\(resource);\(modifyOtherKeysMode)m")
    }

    private func applyXTFMTKEYS(resource: Int, value: Int?) {
        switch resource {
        case 4:
            formatOtherKeysMode = normalizedFormatOtherKeysMode(value)
        case -1:
            formatOtherKeysMode = 0
        default:
            break
        }
    }

    private func respondToXTQFMTKEYS(resource: Int) {
        guard resource == 4 else { return }
        sendResponse("\u{1B}[>\(resource);\(formatOtherKeysMode)f")
    }

    private func normalizedModifyOtherKeysMode(_ value: Int?) -> Int {
        guard let value else { return 0 }
        return min(max(value, 0), 3)
    }

    private func normalizedFormatOtherKeysMode(_ value: Int?) -> Int {
        guard let value else { return 0 }
        return value == 1 ? 1 : 0
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
        case " q":
            sendDCSResponse("1$r\(deccusrStatusParameter()) q")
        case "*|":
            sendDCSResponse("1$r\(reportedLinesPerScreen)*|")
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

    private func deccusrStatusParameter() -> Int {
        switch (cursor.shape, cursor.blinking) {
        case (.block, true): return 1
        case (.block, false): return 2
        case (.underline, true): return 3
        case (.underline, false): return 4
        case (.bar, true): return 5
        case (.bar, false): return 6
        }
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
            // Secondary DA: match WezTerm's current firmware report so vttest
            // sees identical metadata in CLI mode comparisons.
            sendResponse("\u{1B}[>1;277;0c")
        case UInt8(ascii: "="):
            // Tertiary DA (unit ID) for VT420+ class terminals. vttest accepts
            // any eight-digit hexadecimal identifier wrapped in DCS !| ... ST.
            sendDCSResponse("!|00000000")
        default:
            // Primary DA: match WezTerm's VT525-class capabilities so CLI-mode
            // vttest replays can be compared byte-for-byte.
            sendResponse("\u{1B}[?65;4;6;18;22c")
        }
    }

    private func handleDECSCL(parser: UnsafePointer<VtParser>) {
        let requestedLevelCode = Int(vt_parser_param(parser, 0, 61))
        let requestedLevel: Int
        switch requestedLevelCode {
        case 61...65:
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
        defer { clampCursorToVisibleLineWidth() }
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
                switch finalByte {
                case 0x33: // DECDHL top half
                    setCurrentLineAttribute(.doubleHeightTop)
                case 0x34: // DECDHL bottom half
                    setCurrentLineAttribute(.doubleHeightBottom)
                case 0x35: // DECSWL
                    setCurrentLineAttribute(.singleWidth)
                case 0x36: // DECDWL
                    setCurrentLineAttribute(.doubleWidth)
                case 0x38: // DECALN
                    performScreenAlignmentDisplay()
                default:
                    break
                }
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

        case 0x3D: // DECPAM - Application Keypad
            applicationKeypadMode = true

        case 0x3E: // DECPNM - Numeric Keypad
            applicationKeypadMode = false

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

    func handleKittyGraphicsAPCPayloadString(_ payload: String) {
        payload.utf8CString.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, buffer.count > 1 else { return }
            let bytes = UnsafeBufferPointer(
                start: UnsafePointer<UInt8>(OpaquePointer(base)),
                count: buffer.count - 1
            )
            if let job = handleKittyGraphicsAPCPayload(bytes) {
                executeDeferredKittyImagePayload(job)
            }
        }
    }

    func handleKittyGraphicsAPCPayload(_ payload: UnsafeBufferPointer<UInt8>) -> DeferredKittyImagePayloadJob? {
        guard let control = Self.parseKittyGraphicsControl(in: payload) else { return nil }
        let action = control.action
        guard action == UInt8(ascii: "T") || action == UInt8(ascii: "t") else { return nil }
        let imageIndex = resolveKittyImageIndex(for: control)

        let startRow = cursor.row
        let startCol = cursor.col
        let format = control.formatCode.flatMap(TerminalImagePayloadFormat.init(kittyFormatCode:))
        let encodedPayload = UnsafeBufferPointer(
            start: payload.baseAddress!.advanced(by: control.encodedPayloadStart),
            count: payload.count - control.encodedPayloadStart
        )
        if control.hasMoreChunks || kittyImageChunkAccumulators[imageIndex] != nil {
            return handleKittyGraphicsAPCPayload(
                control: control,
                imageIndex: imageIndex,
                startRow: startRow,
                startCol: startCol,
                format: format,
                encodedPayloadBytes: encodedPayload
            )
        }
        let encodedPayloadData = Data(bytes: encodedPayload.baseAddress!, count: encodedPayload.count)

        return handleKittyGraphicsAPCPayload(
            control: control,
            imageIndex: imageIndex,
            startRow: startRow,
            startCol: startCol,
            format: format,
            encodedPayloadSource: .encodedData(encodedPayloadData)
        )
    }

    func handleKittyGraphicsAPCPayload(
        controlPayload: UnsafeBufferPointer<UInt8>,
        encodedPayloadFileURL: URL
    ) -> DeferredKittyImagePayloadJob? {
        guard let control = Self.parseKittyGraphicsControl(in: controlPayload) else {
            Self.removeKittyEncodedPayloadFile(at: encodedPayloadFileURL)
            return nil
        }
        let action = control.action
        guard action == UInt8(ascii: "T") || action == UInt8(ascii: "t") else {
            Self.removeKittyEncodedPayloadFile(at: encodedPayloadFileURL)
            return nil
        }

        let imageIndex = resolveKittyImageIndex(for: control)

        let format = control.formatCode.flatMap(TerminalImagePayloadFormat.init(kittyFormatCode:))
        return handleKittyGraphicsAPCPayload(
            control: control,
            imageIndex: imageIndex,
            startRow: cursor.row,
            startCol: cursor.col,
            format: format,
            encodedPayloadSource: .file(encodedPayloadFileURL)
        )
    }

    private func handleKittyGraphicsAPCPayload(
        control: KittyGraphicsControl,
        imageIndex: Int,
        startRow: Int,
        startCol: Int,
        format: TerminalImagePayloadFormat?,
        encodedPayloadBytes: UnsafeBufferPointer<UInt8>
    ) -> DeferredKittyImagePayloadJob? {
        let transmission = control.transmission
        let compression = control.compression
        let hasMoreChunks = control.hasMoreChunks
        let byteOffset = max(control.byteOffset, 0)
        let byteCount = control.byteCount
        let columnSpan = max(control.columnSpan, 1)
        let rowSpan = max(control.rowSpan, 1)

        if hasMoreChunks {
            if let accumulator = kittyImageChunkAccumulators[imageIndex] {
                guard Self.appendKittyEncodedPayload(encodedPayloadBytes, to: accumulator.encodedPayloadFileURL) else {
                    Self.removeKittyEncodedPayloadFile(at: accumulator.encodedPayloadFileURL)
                    kittyImageChunkAccumulators.removeValue(forKey: imageIndex)
                    clearPendingAnonymousKittyImageChunkIndexIfNeeded(imageIndex)
                    return nil
                }
                return nil
            }

            let payloadFileURL = Self.makeKittyImageEncodedPayloadFileURL()
            guard Self.appendKittyEncodedPayload(encodedPayloadBytes, to: payloadFileURL) else {
                Self.removeKittyEncodedPayloadFile(at: payloadFileURL)
                clearPendingAnonymousKittyImageChunkIndexIfNeeded(imageIndex)
                return nil
            }

            kittyImageChunkAccumulators[imageIndex] = KittyImageChunkAccumulator(
                startRow: startRow,
                startCol: startCol,
                transmission: transmission,
                compression: compression,
                pixelWidth: control.pixelWidth,
                pixelHeight: control.pixelHeight,
                columnSpan: columnSpan,
                rowSpan: rowSpan,
                format: format,
                byteOffset: byteOffset,
                byteCount: byteCount,
                encodedPayloadFileURL: payloadFileURL
            )
            return nil
        }

        guard let accumulator = kittyImageChunkAccumulators.removeValue(forKey: imageIndex) else {
            let encodedPayloadData = Data(bytes: encodedPayloadBytes.baseAddress!, count: encodedPayloadBytes.count)
            return handleKittyGraphicsAPCPayload(
                control: control,
                imageIndex: imageIndex,
                startRow: startRow,
                startCol: startCol,
                format: format,
                encodedPayloadSource: .encodedData(encodedPayloadData)
            )
        }

        guard Self.appendKittyEncodedPayload(encodedPayloadBytes, to: accumulator.encodedPayloadFileURL) else {
            Self.removeKittyEncodedPayloadFile(at: accumulator.encodedPayloadFileURL)
            clearPendingAnonymousKittyImageChunkIndexIfNeeded(imageIndex)
            return nil
        }
        clearPendingAnonymousKittyImageChunkIndexIfNeeded(imageIndex)
        placeInlineImage(
            atRow: accumulator.startRow,
            startCol: accumulator.startCol,
            imageIndex: imageIndex,
            columns: accumulator.columnSpan,
            rows: accumulator.rowSpan
        )
        return DeferredKittyImagePayloadJob(
            imageIndex: imageIndex,
            encodedPayloadSource: .file(accumulator.encodedPayloadFileURL),
            transmission: transmission,
            compression: compression,
            format: format,
            pixelWidth: control.pixelWidth,
            pixelHeight: control.pixelHeight,
            columnSpan: columnSpan,
            rowSpan: rowSpan,
            byteOffset: byteOffset,
            byteCount: byteCount
        )
    }

    private func handleKittyGraphicsAPCPayload(
        control: KittyGraphicsControl,
        imageIndex: Int,
        startRow: Int,
        startCol: Int,
        format: TerminalImagePayloadFormat?,
        encodedPayloadSource: DeferredKittyImagePayloadSource
    ) -> DeferredKittyImagePayloadJob? {
        let transmission = control.transmission
        let compression = control.compression
        let hasMoreChunks = control.hasMoreChunks
        let byteOffset = max(control.byteOffset, 0)
        let byteCount = control.byteCount
        let columnSpan = max(control.columnSpan, 1)
        let rowSpan = max(control.rowSpan, 1)
        let hasExistingAccumulator = kittyImageChunkAccumulators[imageIndex] != nil
        if !hasExistingAccumulator && !hasMoreChunks {
            placeInlineImage(
                atRow: startRow,
                startCol: startCol,
                imageIndex: imageIndex,
                columns: columnSpan,
                rows: rowSpan
            )
        }

        if hasMoreChunks {
            if let accumulator = kittyImageChunkAccumulators[imageIndex] {
                let appendedChunk: Bool
                switch encodedPayloadSource {
                case .file(let encodedPayloadFileURL):
                    if accumulator.encodedPayloadFileURL == encodedPayloadFileURL {
                        appendedChunk = true
                    } else {
                        appendedChunk = Self.appendKittyEncodedPayload(from: encodedPayloadFileURL, to: accumulator.encodedPayloadFileURL)
                        Self.removeKittyEncodedPayloadFile(at: encodedPayloadFileURL)
                    }
                case .encodedData(let data):
                    appendedChunk = data.withUnsafeBytes { rawBuffer -> Bool in
                        guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return true }
                        let payloadBytes = UnsafeBufferPointer(start: baseAddress, count: rawBuffer.count)
                        return Self.appendKittyEncodedPayload(payloadBytes, to: accumulator.encodedPayloadFileURL)
                    }
                }
                guard appendedChunk else {
                    Self.removeKittyEncodedPayloadFile(at: accumulator.encodedPayloadFileURL)
                    kittyImageChunkAccumulators.removeValue(forKey: imageIndex)
                    clearPendingAnonymousKittyImageChunkIndexIfNeeded(imageIndex)
                    return nil
                }
                return nil
            }

            let accumulatorFileURL: URL
            switch encodedPayloadSource {
            case .file(let fileURL):
                accumulatorFileURL = fileURL
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    Self.removeKittyEncodedPayloadFile(at: fileURL)
                    clearPendingAnonymousKittyImageChunkIndexIfNeeded(imageIndex)
                    return nil
                }
            case .encodedData(let data):
                let payloadFileURL = Self.makeKittyImageEncodedPayloadFileURL()
                let appendedChunk = data.withUnsafeBytes { rawBuffer -> Bool in
                    guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return true }
                    let payloadBytes = UnsafeBufferPointer(start: baseAddress, count: rawBuffer.count)
                    return Self.appendKittyEncodedPayload(payloadBytes, to: payloadFileURL)
                }
                guard appendedChunk else {
                    Self.removeKittyEncodedPayloadFile(at: payloadFileURL)
                    clearPendingAnonymousKittyImageChunkIndexIfNeeded(imageIndex)
                    return nil
                }
                accumulatorFileURL = payloadFileURL
            }
            kittyImageChunkAccumulators[imageIndex] = KittyImageChunkAccumulator(
                startRow: startRow,
                startCol: startCol,
                transmission: transmission,
                compression: compression,
                pixelWidth: control.pixelWidth,
                pixelHeight: control.pixelHeight,
                columnSpan: columnSpan,
                rowSpan: rowSpan,
                format: format,
                byteOffset: byteOffset,
                byteCount: byteCount,
                encodedPayloadFileURL: accumulatorFileURL
            )
            return nil
        }

        let resolvedPayloadSource: DeferredKittyImagePayloadSource
        if let accumulator = kittyImageChunkAccumulators.removeValue(forKey: imageIndex) {
            switch encodedPayloadSource {
            case .file(let encodedPayloadFileURL):
                if accumulator.encodedPayloadFileURL != encodedPayloadFileURL {
                    let appendedChunk = Self.appendKittyEncodedPayload(from: encodedPayloadFileURL, to: accumulator.encodedPayloadFileURL)
                    Self.removeKittyEncodedPayloadFile(at: encodedPayloadFileURL)
                    guard appendedChunk else {
                        Self.removeKittyEncodedPayloadFile(at: accumulator.encodedPayloadFileURL)
                        clearPendingAnonymousKittyImageChunkIndexIfNeeded(imageIndex)
                        return nil
                    }
                }
            case .encodedData(let data):
                let appendedChunk = data.withUnsafeBytes { rawBuffer -> Bool in
                    guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return true }
                    let payloadBytes = UnsafeBufferPointer(start: baseAddress, count: rawBuffer.count)
                    return Self.appendKittyEncodedPayload(payloadBytes, to: accumulator.encodedPayloadFileURL)
                }
                guard appendedChunk else {
                    Self.removeKittyEncodedPayloadFile(at: accumulator.encodedPayloadFileURL)
                    clearPendingAnonymousKittyImageChunkIndexIfNeeded(imageIndex)
                    return nil
                }
            }
            resolvedPayloadSource = .file(accumulator.encodedPayloadFileURL)
            clearPendingAnonymousKittyImageChunkIndexIfNeeded(imageIndex)
            placeInlineImage(
                atRow: accumulator.startRow,
                startCol: accumulator.startCol,
                imageIndex: imageIndex,
                columns: accumulator.columnSpan,
                rows: accumulator.rowSpan
            )
        } else {
            resolvedPayloadSource = encodedPayloadSource
        }

        return DeferredKittyImagePayloadJob(
            imageIndex: imageIndex,
            encodedPayloadSource: resolvedPayloadSource,
            transmission: transmission,
            compression: compression,
            format: format,
            pixelWidth: control.pixelWidth,
            pixelHeight: control.pixelHeight,
            columnSpan: columnSpan,
            rowSpan: rowSpan,
            byteOffset: byteOffset,
            byteCount: byteCount
        )
    }

    private func resolveKittyImageIndex(for control: KittyGraphicsControl) -> Int {
        if let parsed = control.imageIndex {
            nextKittyImagePlaceholderIndex = max(nextKittyImagePlaceholderIndex, parsed + 1)
            if control.hasMoreChunks {
                pendingKittyImageChunkContinuationIndex = parsed
            }
            return parsed
        }

        if control.hasMoreChunks || pendingKittyImageChunkContinuationIndex != nil {
            if let pendingKittyImageChunkContinuationIndex {
                return pendingKittyImageChunkContinuationIndex
            }
            let placeholder = nextKittyImagePlaceholderIndex
            nextKittyImagePlaceholderIndex += 1
            pendingKittyImageChunkContinuationIndex = placeholder
            return placeholder
        }

        let placeholder = nextKittyImagePlaceholderIndex
        nextKittyImagePlaceholderIndex += 1
        return placeholder
    }

    private func clearPendingAnonymousKittyImageChunkIndexIfNeeded(_ imageIndex: Int) {
        if pendingKittyImageChunkContinuationIndex == imageIndex {
            pendingKittyImageChunkContinuationIndex = nil
        }
    }

    func executeDeferredKittyImagePayload(_ job: DeferredKittyImagePayloadJob) {
        guard let decodedPayload = Self.resolveKittyGraphicsPayload(
            encodedPayloadSource: job.encodedPayloadSource,
            transmission: job.transmission,
            compression: job.compression,
            format: job.format,
            pixelWidth: job.pixelWidth,
            pixelHeight: job.pixelHeight,
            byteOffset: job.byteOffset,
            byteCount: job.byteCount
        ),
        !decodedPayload.isEmpty else {
            return
        }

        let resolvedFormat = job.format ?? inferredKittyImagePayloadFormat(for: decodedPayload)
        guard let resolvedFormat else { return }

        onKittyImagePayload?(
            job.imageIndex,
            decodedPayload,
            resolvedFormat,
            job.pixelWidth,
            job.pixelHeight,
            job.columnSpan,
            job.rowSpan
        )
    }

    private static func parseKittyGraphicsControl(in payload: UnsafeBufferPointer<UInt8>) -> KittyGraphicsControl? {
        guard let base = payload.baseAddress, payload.count >= 1, base[0] == UInt8(ascii: "G") else {
            return nil
        }

        var control = KittyGraphicsControl()
        var semicolonIndex = payload.count
        var index = 1
        while index < payload.count {
            if base[index] == UInt8(ascii: ";") {
                semicolonIndex = index
                break
            }
            index += 1
        }
        control.encodedPayloadStart = min(semicolonIndex + 1, payload.count)

        var entryStart = 1
        while entryStart < semicolonIndex {
            var entryEnd = entryStart
            while entryEnd < semicolonIndex, base[entryEnd] != UInt8(ascii: ",") {
                entryEnd += 1
            }

            var equalsIndex = entryStart
            while equalsIndex < entryEnd, base[equalsIndex] != UInt8(ascii: "=") {
                equalsIndex += 1
            }

            if equalsIndex < entryEnd {
                let key = base[entryStart]
                let valueStart = equalsIndex + 1
                let value = UnsafeBufferPointer(
                    start: base.advanced(by: valueStart),
                    count: entryEnd - valueStart
                )
                switch key {
                case UInt8(ascii: "a"):
                    control.action = value.first ?? control.action
                case UInt8(ascii: "t"):
                    control.transmission = value.first ?? control.transmission
                case UInt8(ascii: "o"):
                    control.compression = value.first
                case UInt8(ascii: "m"):
                    control.hasMoreChunks = value.count == 1 && value[0] == UInt8(ascii: "1")
                case UInt8(ascii: "O"):
                    control.byteOffset = max(parseASCIIInt(value) ?? 0, 0)
                case UInt8(ascii: "S"):
                    control.byteCount = parseASCIIInt(value)
                case UInt8(ascii: "i"):
                    control.imageIndex = parseASCIIInt(value)
                case UInt8(ascii: "c"):
                    control.columnSpan = max(parseASCIIInt(value) ?? 1, 1)
                case UInt8(ascii: "r"):
                    control.rowSpan = max(parseASCIIInt(value) ?? 1, 1)
                case UInt8(ascii: "s"):
                    control.pixelWidth = parseASCIIInt(value)
                case UInt8(ascii: "v"):
                    control.pixelHeight = parseASCIIInt(value)
                case UInt8(ascii: "f"):
                    control.formatCode = parseASCIIInt(value)
                default:
                    break
                }
            }

            entryStart = entryEnd + 1
        }

        return control
    }

    private static func parseASCIIInt(_ bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        guard !bytes.isEmpty else { return nil }
        var value = 0
        for byte in bytes {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            let (product, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = product.addingReportingOverflow(Int(byte - UInt8(ascii: "0")))
            if overflow1 || overflow2 { return Int.max }
            value = sum
        }
        return value
    }

    private static func resolveKittyGraphicsPayload(
        encodedPayloadSource: DeferredKittyImagePayloadSource,
        transmission: UInt8,
        compression: UInt8?,
        format: TerminalImagePayloadFormat?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        byteOffset: Int,
        byteCount: Int?
    ) -> Data? {
        let encodedPayloadData: Data
        switch encodedPayloadSource {
        case .file(let encodedPayloadFileURL):
            defer { removeKittyEncodedPayloadFile(at: encodedPayloadFileURL) }
            guard let loaded = try? Data(contentsOf: encodedPayloadFileURL, options: .mappedIfSafe) else {
                return nil
            }
            encodedPayloadData = loaded
        case .encodedData(let data):
            encodedPayloadData = data
        }
        let loadedData: Data?
        switch transmission {
        case UInt8(ascii: "d"):
            loadedData = Data(base64Encoded: encodedPayloadData)
        case UInt8(ascii: "f"):
            guard let pathData = Data(base64Encoded: encodedPayloadData) else {
                return nil
            }
            let path = String(decoding: pathData, as: UTF8.self)
            loadedData = loadKittyGraphicsFilePayload(
                atPath: path,
                byteOffset: byteOffset,
                byteCount: byteCount
            )
        case UInt8(ascii: "s"):
            guard let nameData = Data(base64Encoded: encodedPayloadData) else {
                return nil
            }
            let name = String(decoding: nameData, as: UTF8.self)
            loadedData = loadKittyGraphicsSharedMemoryPayload(
                named: name,
                byteOffset: byteOffset,
                byteCount: byteCount
            )
        default:
            loadedData = nil
        }

        guard let loadedData else { return nil }
        guard compression == UInt8(ascii: "z") else { return loadedData }
        return decompressKittyGraphicsPayload(
            loadedData,
            format: format,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    private static func removeKittyEncodedPayloadFile(at fileURL: URL) {
        let result = fileURL.withUnsafeFileSystemRepresentation { rawPath -> Int32 in
            guard let rawPath else { return 0 }
            return unlink(rawPath)
        }
        if result != 0 && errno != ENOENT {
            _ = try? FileManager.default.removeItem(at: fileURL)
        }
    }

    static func makeKittyImageEncodedPayloadFileURL() -> URL {
        kittyImageEncodedPayloadDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("b64")
    }

    private static func createKittyEncodedPayloadFile(at fileURL: URL) -> Int32? {
        let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, S_IRUSR | S_IWUSR)
        return descriptor >= 0 ? descriptor : nil
    }

    private static func openKittyEncodedPayloadFileForAppending(at fileURL: URL) -> Int32? {
        let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        return descriptor >= 0 ? descriptor : nil
    }

    private static func appendKittyEncodedPayload(
        _ bytes: UnsafeBufferPointer<UInt8>,
        to fileURL: URL
    ) -> Bool {
        guard bytes.baseAddress != nil else { return true }

        let fd: Int32
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let descriptor = openKittyEncodedPayloadFileForAppending(at: fileURL) else { return false }
            fd = descriptor
        } else {
            guard let descriptor = createKittyEncodedPayloadFile(at: fileURL) else { return false }
            fd = descriptor
        }
        guard fd >= 0 else { return false }
        defer { close(fd) }

        return appendKittyEncodedPayload(bytes, to: fd)
    }

    private static func appendKittyEncodedPayload(
        from sourceFileURL: URL,
        to destinationFileURL: URL
    ) -> Bool {
        let destinationDescriptor: Int32
        if FileManager.default.fileExists(atPath: destinationFileURL.path) {
            guard let descriptor = openKittyEncodedPayloadFileForAppending(at: destinationFileURL) else { return false }
            destinationDescriptor = descriptor
        } else {
            guard let descriptor = createKittyEncodedPayloadFile(at: destinationFileURL) else { return false }
            destinationDescriptor = descriptor
        }
        defer { close(destinationDescriptor) }
        return appendKittyEncodedPayload(from: sourceFileURL, to: destinationDescriptor)
    }

    private static func appendKittyEncodedPayload(
        _ bytes: UnsafeBufferPointer<UInt8>,
        to fileDescriptor: Int32
    ) -> Bool {
        guard let baseAddress = bytes.baseAddress else { return true }

        var bytesRemaining = bytes.count
        var currentPointer = baseAddress
        while bytesRemaining > 0 {
            let written = write(fileDescriptor, currentPointer, bytesRemaining)
            if written <= 0 {
                return false
            }
            bytesRemaining -= written
            currentPointer = currentPointer.advanced(by: written)
        }
        return true
    }

    private static func appendKittyEncodedPayload(
        from sourceFileURL: URL,
        to destinationFileDescriptor: Int32
    ) -> Bool {
        let sourceDescriptor = open(sourceFileURL.path, O_RDONLY | O_CLOEXEC)
        guard sourceDescriptor >= 0 else { return false }
        defer { close(sourceDescriptor) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let bytesRead = read(sourceDescriptor, &buffer, buffer.count)
            if bytesRead < 0 {
                return false
            }
            if bytesRead == 0 {
                return true
            }

            let chunk = buffer.withUnsafeBufferPointer {
                UnsafeBufferPointer(start: $0.baseAddress, count: bytesRead)
            }
            if !appendKittyEncodedPayload(chunk, to: destinationFileDescriptor) {
                return false
            }
        }
    }

    private static let kittyGraphicsAllowedDirectories: [String] = {
        let candidates = [
            NSTemporaryDirectory(),
            "/tmp",
            "/var/tmp",
        ]
        return candidates.compactMap { dir in
            try? FileManager.default.attributesOfItem(atPath: dir)
            let resolved = (dir as NSString).resolvingSymlinksInPath
            return resolved.hasSuffix("/") ? resolved : resolved + "/"
        }
    }()

    private static func isPathInAllowedDirectory(_ resolvedPath: String) -> Bool {
        for allowed in kittyGraphicsAllowedDirectories {
            if resolvedPath.hasPrefix(allowed) {
                return true
            }
        }
        return false
    }

    private static func loadKittyGraphicsFilePayload(
        atPath path: String,
        byteOffset: Int,
        byteCount: Int?
    ) -> Data? {
        let url = URL(fileURLWithPath: path)
        guard url.isFileURL else { return nil }
        let standardizedURL = url.standardizedFileURL

        // Resolve symlinks to check the allowed-directory policy.
        let resolvedPath = (standardizedURL.path as NSString).resolvingSymlinksInPath
        guard isPathInAllowedDirectory(resolvedPath) else {
            NSLog("[pterm] Kitty graphics: rejected file read outside allowed directories: %@", path)
            return nil
        }

        // Open with O_NOFOLLOW to prevent a TOCTOU race where the file is
        // replaced with a symlink between the path check above and the open.
        // Then validate properties on the open fd via fstat, not the path.
        let descriptor = open(resolvedPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var st = stat()
        guard fstat(descriptor, &st) == 0 else { return nil }

        // Must be a regular file (validated on the open fd, race-free).
        guard (st.st_mode & S_IFMT) == S_IFREG else { return nil }

        let fileLength = Int(st.st_size)
        guard fileLength > 0, byteOffset >= 0, byteOffset < fileLength else {
            return nil
        }
        let bytesToRead = min(byteCount ?? (fileLength - byteOffset), fileLength - byteOffset)
        guard bytesToRead > 0 else { return nil }

        guard let mapped = mmap(nil, fileLength, PROT_READ, MAP_PRIVATE, descriptor, 0),
              mapped != MAP_FAILED else {
            return nil
        }

        let base = mapped.advanced(by: byteOffset)
        return Data(
            bytesNoCopy: base,
            count: bytesToRead,
            deallocator: .custom { _, _ in
                munmap(mapped, fileLength)
            }
        )
    }

    private static func isValidSharedMemoryName(_ name: String) -> Bool {
        // Must start with '/', max 255 chars, only alphanumeric/hyphen/underscore after leading '/'
        guard name.hasPrefix("/"),
              name.count >= 2,
              name.count <= 255 else {
            return false
        }
        let body = name.dropFirst()
        // No additional path separators allowed; only [A-Za-z0-9_-]
        return body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func loadKittyGraphicsSharedMemoryPayload(
        named name: String,
        byteOffset: Int,
        byteCount: Int?
    ) -> Data? {
        guard isValidSharedMemoryName(name) else {
            NSLog("[pterm] Kitty graphics: rejected invalid shared memory name: %@", name)
            return nil
        }
        let descriptor = name.withCString { posixShmOpen($0, O_RDONLY, 0) }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var statBuffer = stat()
        guard fstat(descriptor, &statBuffer) == 0 else { return nil }
        let mappingLength = Int(statBuffer.st_size)
        guard mappingLength > 0, byteOffset >= 0, byteOffset < mappingLength else { return nil }
        let bytesToRead = min(byteCount ?? (mappingLength - byteOffset), mappingLength - byteOffset)
        guard bytesToRead > 0 else { return nil }

        guard let mapped = mmap(nil, mappingLength, PROT_READ, MAP_SHARED, descriptor, 0),
              mapped != MAP_FAILED else {
            return nil
        }
        _ = name.withCString { shm_unlink($0) }

        let base = mapped.advanced(by: byteOffset)
        return Data(
            bytesNoCopy: base,
            count: bytesToRead,
            deallocator: .custom { _, _ in
                munmap(mapped, mappingLength)
            }
        )
    }

    /// Maximum pixel dimension for Kitty graphics raw image formats.
    /// Matches common GPU texture limits and prevents integer overflow
    /// in size calculations (16384 * 16384 * 4 = 1 GB, within bounds).
    private static let kittyGraphicsMaxPixelDimension = 16384

    /// Maximum decompressed output size for Kitty graphics payloads (256 MB).
    /// Prevents decompression bomb attacks where a small compressed payload
    /// expands to gigabytes of memory.
    private static let kittyGraphicsMaxDecompressedSize = 256 * 1024 * 1024

    private static func decompressKittyGraphicsPayload(
        _ data: Data,
        format: TerminalImagePayloadFormat?,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) -> Data? {
        let expectedSize: Int? = {
            switch format {
            case .rawRGB:
                guard let pixelWidth, pixelWidth > 0, pixelWidth <= kittyGraphicsMaxPixelDimension,
                      let pixelHeight, pixelHeight > 0, pixelHeight <= kittyGraphicsMaxPixelDimension else {
                    return nil
                }
                // Overflow-safe: max is 16384 * 16384 * 3 = 805,306,368 (fits in Int)
                return pixelWidth * pixelHeight * 3
            case .rawRGBA:
                guard let pixelWidth, pixelWidth > 0, pixelWidth <= kittyGraphicsMaxPixelDimension,
                      let pixelHeight, pixelHeight > 0, pixelHeight <= kittyGraphicsMaxPixelDimension else {
                    return nil
                }
                return pixelWidth * pixelHeight * 4
            case .png, .jpeg, .gif, .webp, .none:
                return nil
            }
        }()

        let dummyDestination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let dummySource = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer {
            dummyDestination.deallocate()
            dummySource.deallocate()
        }
        var stream = compression_stream(
            dst_ptr: dummyDestination,
            dst_size: 0,
            src_ptr: UnsafePointer(dummySource),
            src_size: 0,
            state: nil
        )
        var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else { return nil }
        defer { compression_stream_destroy(&stream) }

        let maxOutput = expectedSize ?? kittyGraphicsMaxDecompressedSize
        let destinationChunkSize = min(max(expectedSize ?? 0, 64 * 1024), maxOutput)
        var destination = Data()
        if let expectedSize {
            destination.reserveCapacity(expectedSize)
        }

        return data.withUnsafeBytes { sourceBuffer -> Data? in
            guard let sourceBase = sourceBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            stream.src_ptr = sourceBase
            stream.src_size = data.count

            var chunk = [UInt8](repeating: 0, count: destinationChunkSize)
            repeat {
                let chunkCount = chunk.count
                var produced = 0
                chunk.withUnsafeMutableBytes { destinationBuffer in
                    stream.dst_ptr = destinationBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    stream.dst_size = chunkCount
                    status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    produced = chunkCount - stream.dst_size
                }
                if produced > 0 {
                    destination.append(contentsOf: chunk.prefix(produced))
                }
                // Abort if decompressed output exceeds the maximum allowed size
                // to prevent decompression bomb attacks.
                if destination.count > maxOutput {
                    return nil
                }
            } while status == COMPRESSION_STATUS_OK

            guard status == COMPRESSION_STATUS_END else { return nil }
            return destination
        }
    }

    private func placeInlineImage(atRow startRow: Int, startCol: Int, imageIndex: Int, columns: Int, rows rowSpan: Int) {
        let clampedColumns = max(1, min(columns, cols - startCol))
        let clampedRows = max(1, min(rowSpan, self.rows - startRow))
        guard clampedColumns > 0, clampedRows > 0 else { return }

        for rowOffset in 0..<clampedRows {
            for colOffset in 0..<clampedColumns {
                grid.setCell(
                    .inlineImage(
                        id: imageIndex,
                        columns: clampedColumns,
                        rows: clampedRows,
                        originColOffset: colOffset,
                        originRowOffset: rowOffset
                    ),
                    at: startRow + rowOffset,
                    col: startCol + colOffset
                )
            }
        }

        if startCol + clampedColumns >= cols {
            cursor.col = cols - 1
            cursor.pendingWrap = true
        } else {
            cursor.col = startCol + clampedColumns
            cursor.pendingWrap = false
        }
    }

    private func inferredKittyImagePayloadFormat(for payload: Data) -> TerminalImagePayloadFormat? {
        if payload.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return .png
        }
        if payload.starts(with: [0xFF, 0xD8, 0xFF]) {
            return .jpeg
        }
        if payload.starts(with: Array("GIF8".utf8)) {
            return .gif
        }
        if payload.starts(with: Array("RIFF".utf8)), payload.dropFirst(8).starts(with: Array("WEBP".utf8)) {
            return .webp
        }
        return nil
    }

    private func performScreenAlignmentDisplay() {
        cursor.originMode = false
        cursor.row = 0
        cursor.col = 0
        cursor.pendingWrap = false
        grid.scrollTop = 0
        grid.scrollBottom = rows - 1

        let fill = Cell(
            codepoint: 0x45,
            attributes: currentPrintAttributes(),
            width: 1,
            isWideContinuation: false
        )

        for row in 0..<rows {
            grid.setLineAttribute(.singleWidth, at: row)
            for col in 0..<cols {
                grid.setCell(fill, at: row, col: col)
            }
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

    /// Characters allowed in the OSC 52 target parameter per the specification:
    /// clipboard selections c, p, q, s, and cut buffers 0-7.
    private static let osc52AllowedTargetCharacters = CharacterSet(charactersIn: "cpsq01234567")

    private func handleOSC52(_ payload: String) {
        let components = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else { return }
        let target = String(components[0])
        let data = String(components[1])

        // Validate target to prevent response injection.  An unsanitized target
        // echoed into the response could contain BEL (0x07) or other control
        // characters that terminate the OSC sequence early, allowing a malicious
        // child process to inject arbitrary escape sequences into the response stream.
        guard !target.isEmpty,
              target.unicodeScalars.allSatisfy({ Self.osc52AllowedTargetCharacters.contains($0) }) else {
            return
        }

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
        // Reject decoded payloads exceeding 100 KB to prevent excessive clipboard writes
        let maxDecodedSize = 100 * 1024
        guard decoded.count <= maxDecodedSize else {
            NSLog("OSC 52: rejected clipboard write of %d bytes (limit: %d)", decoded.count, maxDecodedSize)
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
        applicationKeypadMode = false
        newLineMode = false
        mouseReporting = .none
        mouseProtocol = .x10
        focusTrackingEnabled = false
        pendingUpdateModeEnabled = false
        reverseVideoEnabled = false
        insertModeEnabled = false
        isAlternateScreen = false
        alternateGrid = nil
        reportedLinesPerScreen = rows
        g0Charset = .ascii
        g1Charset = .ascii
        g2Charset = .ascii
        g3Charset = .ascii
        glInvocation = .g0
        grInvocation = .g1
        singleShiftInvocation = nil
        protectedAreaModeEnabled = false
        responseControlsUse8Bit = false
        modifyOtherKeysMode = 0
        formatOtherKeysMode = 0
        modifyOtherKeysMask = 0
        initTabStops()
        onPendingUpdateModeChange?(false)
    }

    private func softReset() {
        cursor = CursorState()
        grid.scrollTop = 0
        grid.scrollBottom = rows - 1
        bracketedPasteMode = false
        applicationCursorKeys = false
        applicationKeypadMode = false
        newLineMode = false
        mouseReporting = .none
        mouseProtocol = .x10
        focusTrackingEnabled = false
        pendingUpdateModeEnabled = false
        reverseVideoEnabled = false
        insertModeEnabled = false
        reportedLinesPerScreen = rows
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

    private func repeatPreviousGraphicCharacter(count: Int) {
        guard count > 0 else { return }
        let prevCell = cursor.col > 0
            ? grid.cell(at: cursor.row, col: cursor.col - 1)
            : Cell.empty
        guard prevCell.codepoint != 0 else { return }
        if prevCell.hasGraphemeTail {
            let scalars = prevCell.graphemeScalars()
            for _ in 0..<count {
                for scalar in scalars {
                    handlePrint(scalar)
                }
            }
            return
        }

        let currentAttributes = currentPrintAttributes()
        if prevCell.width == 1,
           !prevCell.isWideContinuation,
           prevCell.attributes == currentAttributes,
           prevCell.codepoint >= 0x20,
           prevCell.codepoint < 0x7F,
           g0Charset == .ascii,
           g1Charset == .ascii,
           g2Charset == .ascii,
           g3Charset == .ascii,
           singleShiftInvocation == nil {
            handleRepeatedASCIIByte(UInt8(prevCell.codepoint), count: count)
            return
        }

        for _ in 0..<count {
            handlePrint(prevCell.codepoint)
        }
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
        lhs.isWideContinuation == rhs.isWideContinuation &&
        lhs.graphemeTailCount == rhs.graphemeTailCount &&
        lhs.graphemeTail0 == rhs.graphemeTail0 &&
        lhs.graphemeTail1 == rhs.graphemeTail1 &&
        lhs.graphemeTail2 == rhs.graphemeTail2 &&
        lhs.graphemeTail3 == rhs.graphemeTail3 &&
        lhs.graphemeTail4 == rhs.graphemeTail4 &&
        lhs.graphemeTail5 == rhs.graphemeTail5 &&
        lhs.graphemeTail6 == rhs.graphemeTail6
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
        reportedLinesPerScreen = newRows
        cursor.row = result.cursorRow
        cursor.col = result.cursorCol
        cursor.pendingWrap = false
        initTabStops()
        clampCursorToVisibleLineWidth()
    }

    func reconcileCachedDimensionsWithActiveGrid() {
        let dimensions = grid.readableDimensions()
        rows = dimensions.rows
        cols = dimensions.cols
    }


}

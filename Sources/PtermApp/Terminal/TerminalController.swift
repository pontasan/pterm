import AppKit
import Foundation
import PtermCore

/// Coordinates PTY, VT parser, terminal model, and ring buffer.
///
/// This is the central controller for a single terminal session.
/// The PTY read thread writes to the ring buffer and feeds the VT parser.
/// The main thread reads the model for rendering.
///
/// Thread safety: All access to model, parser, decoder, and scrollback
/// is synchronized through `lock`. The PTY read thread acquires a write
/// lock for the entire decode+parse operation, while rendering and search
/// paths take shared read locks.
final class TerminalController {
    private struct ViewportRow {
        let cells: [Cell]
        let isWrapped: Bool
    }

    struct DetectedLink {
        let url: URL
        let originalText: String
        let startCol: Int
        let endCol: Int
    }

    struct SearchMatch: Equatable {
        let absoluteRow: Int
        let startCol: Int
        let endCol: Int
    }

    /// Terminal model (grid + cursor + state)
    let model: TerminalModel

    /// PTY connection
    let pty: PTY

    /// Scrollback buffer (ring buffer for terminal history)
    let scrollback: ScrollbackBuffer

    /// Scroll offset: number of lines scrolled back from the bottom.
    /// 0 = at the bottom (normal operation), >0 = viewing history.
    private(set) var scrollOffset: Int = 0

    /// VT parser (C struct)
    private var parser: VtParser = VtParser()

    /// Configured terminal text decoder
    private var textDecoder: TerminalTextDecoder

    /// Unique identifier
    let id: UUID

    /// Terminal title for UI/persistence purposes.
    /// By specification, the default title is always the current directory name
    /// unless the user explicitly overrides it.
    var title: String {
        lock.withReadLock {
            customTitle ?? currentDirectory
        }
    }

    /// User-set custom title (overrides OSC title)
    var customTitle: String?

    /// Workspace grouping name for persistence/audit.
    private(set) var workspaceName: String

    /// Current working directory
    private(set) var currentDirectory: String = "~"
    private var currentDirectoryPath: String

    /// Whether this terminal is still alive
    var isAlive: Bool { pty.isRunning }

    var processID: pid_t { pty.childPID }
    var foregroundProcessID: pid_t? { pty.foregroundProcessGroupID() }

    /// Allocated scrollback buffer capacity in bytes
    var scrollbackCapacity: UInt64 {
        lock.withReadLock { UInt64(scrollback.capacity) }
    }

    /// Lock for thread-safe model/parser/decoder/scrollback access
    private let lock = ReadWriteLock()

    /// Callback when terminal needs redraw
    var onNeedsDisplay: (() -> Void)?
    var onOutputActivity: (() -> Void)?

    /// Callback when terminal exits
    var onExit: (() -> Void)?

    /// Callback when title changes
    var onTitleChange: ((String) -> Void)?
    var onStateChange: (() -> Void)?

    /// Decode buffer for UTF-8 -> codepoints
    private var codepointBuffer = [UInt32](repeating: 0, count: 16384)

    private let termEnv: String
    private let textEncoding: TerminalTextEncoding
    private var persistedFontName: String
    private var persistedFontSize: Double
    private let initialDirectory: String
    private let scrollbackPersistenceEnabled: Bool
    private var parserRequestedScrollbackClear = false
    var auditLogger: TerminalAuditLogger?

    var persistedSettings: PersistedTerminalSettings {
        PersistedTerminalSettings(
            textEncoding: textEncoding.rawValue,
            fontName: persistedFontName,
            fontSize: persistedFontSize
        )
    }

    var persistedFontSettings: (name: String, size: Double) {
        lock.withReadLock {
            (persistedFontName, persistedFontSize)
        }
    }

    init(rows: Int, cols: Int, termEnv: String, textEncoding: TerminalTextEncoding,
         scrollbackInitialCapacity: Int,
         scrollbackMaxCapacity: Int,
         fontName: String,
         fontSize: Double,
         initialDirectory: String? = nil, customTitle: String? = nil,
         workspaceName: String = "Uncategorized", id: UUID = UUID(),
         scrollbackPersistencePath: String? = nil) {
        self.model = TerminalModel(rows: rows, cols: cols)
        self.pty = PTY()
        self.scrollback = ScrollbackBuffer(
            initialCapacity: scrollbackInitialCapacity,
            maxCapacity: scrollbackMaxCapacity,
            persistentPath: scrollbackPersistencePath
        )
        self.termEnv = termEnv
        self.textEncoding = textEncoding
        self.textDecoder = TerminalTextDecoder(encoding: textEncoding)
        self.persistedFontName = fontName
        self.persistedFontSize = fontSize
        self.initialDirectory = (initialDirectory as NSString?)?.expandingTildeInPath
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.scrollbackPersistenceEnabled = scrollbackPersistencePath != nil
        self.customTitle = customTitle
        self.workspaceName = FileNameSanitizer.sanitize(workspaceName, fallback: "Uncategorized")
        self.id = id
        self.currentDirectoryPath = self.initialDirectory
        self.currentDirectory = Self.displayDirectoryName(for: self.initialDirectory)

        setupParser()
        setupModelCallbacks()
    }

    deinit {
        pty.stop()
        vt_parser_destroy(&parser)
    }

    // MARK: - Setup

    private func setupParser() {
        vt_parser_init(&parser, { parserPtr, action, codepoint, userData in
            guard let userData = userData else { return }
            let controller = Unmanaged<TerminalController>.fromOpaque(userData)
                .takeUnretainedValue()
            guard let parserPtr = parserPtr else { return }
            controller.model.handleAction(action, codepoint: codepoint,
                                          parser: parserPtr)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func setupModelCallbacks() {
        model.onTitleChange = { [weak self] title in
            DispatchQueue.main.async {
                self?.onTitleChange?(title)
            }
        }

        model.onResponse = { [weak self] response in
            guard let self = self else { return }
            guard let data = self.textEncoding.encode(response) else { return }
            // Queue write to avoid blocking model lock on I/O
            DispatchQueue.global(qos: .userInteractive).async {
                self.pty.write(data)
            }
        }

        model.encodeText = { [textEncoding] string in
            textEncoding.encode(string)
        }
        model.decodeText = { [textEncoding] data in
            textEncoding.decode(data)
        }

        model.onBell = {
            DispatchQueue.main.async {
                NSSound.beep()
            }
        }

        model.onClearScrollback = { [weak self] in
            // This callback is invoked while the controller write lock is held
            // during VT parsing, so only record intent here and clear after parsing.
            self?.parserRequestedScrollbackClear = true
        }

        // Wire scrollback: when a line scrolls off the top, store it
        model.onScrollOut = { [weak self] cells, isWrapped in
            guard let self = self else { return }
            self.scrollback.appendRow(ArraySlice(cells), isWrapped: isWrapped)

            // If user is scrolled back, increment offset to keep viewport stable
            if self.scrollOffset > 0 {
                self.scrollOffset += 1
            }
        }
    }

    // MARK: - Start / Stop

    func start() throws {
        pty.onOutput = { [weak self] data in
            self?.handlePTYOutput(data)
        }

        pty.onExit = { [weak self] in
            self?.onExit?()
        }

        let (r, c) = lock.withReadLock {
            (model.rows, model.cols)
        }

        try pty.start(rows: UInt16(r), cols: UInt16(c), termEnv: termEnv,
                      initialDirectory: initialDirectory)
    }

    func stop(waitForExit: Bool = false) {
        pty.stop(waitForExit: waitForExit)
    }

    func discardPersistentScrollback() {
        lock.withWriteLock {
            scrollback.discardPersistentBackingStore()
        }
    }

    func restorePersistedScrollbackToViewport() {
        lock.withWriteLock {
            if scrollbackPersistenceEnabled && scrollback.rowCount > 0 {
                scrollOffset = min(scrollback.rowCount, model.rows)
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.onNeedsDisplay?()
        }
    }

    func clearScrollback() {
        lock.withWriteLock {
            scrollback.clear()
            scrollOffset = 0
        }
        DispatchQueue.main.async { [weak self] in
            self?.onNeedsDisplay?()
            self?.onStateChange?()
        }
    }

    func updateCurrentDirectory(path: String) {
        let normalized = Self.displayDirectoryName(for: path)
        let expandedPath = (path as NSString).expandingTildeInPath

        let titleOverridden = lock.withWriteLock { () -> Bool in
            let overridden = customTitle != nil
            currentDirectoryPath = expandedPath
            currentDirectory = normalized
            return overridden
        }

        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?()
            if !titleOverridden {
                self?.onTitleChange?(normalized)
            }
        }
    }

    func setCustomTitle(_ title: String?) {
        let effectiveTitle = lock.withWriteLock { () -> String in
            customTitle = title?.isEmpty == true ? nil : title
            return customTitle ?? currentDirectory
        }

        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?()
            self?.onTitleChange?(effectiveTitle)
        }
    }

    func setWorkspaceName(_ name: String) {
        lock.withWriteLock {
            workspaceName = FileNameSanitizer.sanitize(name, fallback: "Uncategorized")
        }
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?()
        }
    }

    func updateFontSettings(name: String, size: Double, notify: Bool = true) {
        lock.withWriteLock {
            persistedFontName = name
            persistedFontSize = size
        }

        guard notify else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?()
        }
    }

    var sessionSnapshot: PersistedTerminalState {
        lock.withReadLock {
            PersistedTerminalState(
                id: id,
                workspaceName: workspaceName,
                titleOverride: customTitle,
                currentDirectory: currentDirectoryPath,
                settings: persistedSettings
            )
        }
    }

    // MARK: - Input

    /// Send user keyboard input to the PTY.
    func sendInput(_ data: Data) {
        auditLogger?.recordInput(data)
        pty.write(data)
    }

    /// Send a string as input to the PTY.
    func sendInput(_ string: String) {
        guard let data = textEncoding.encode(string) else { return }
        auditLogger?.recordInput(data)
        pty.write(data)
    }

    // MARK: - PTY Output Processing

    /// Handle raw bytes from PTY output.
    /// Called on the PTY read thread - must be thread-safe.
    /// The entire decode + parse pipeline runs under lock to ensure
    /// decoder and parser state are never accessed concurrently.
    private func handlePTYOutput(_ data: Data) {
        auditLogger?.recordOutput(data)
        var clearedScrollback = false
        data.withUnsafeBytes { rawPtr in
            guard let ptr = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            let count = rawPtr.count

            lock.withWriteLock {
                let cpCount = textDecoder.decode(
                    UnsafeBufferPointer(start: ptr, count: count),
                    into: &codepointBuffer
                )

                // Feed codepoints to VT parser (which updates the model)
                if cpCount > 0 {
                    vt_parser_feed(&parser, codepointBuffer, cpCount)
                }

                if parserRequestedScrollbackClear {
                    scrollback.clear()
                    scrollOffset = 0
                    parserRequestedScrollbackClear = false
                    clearedScrollback = true
                }
            }
        }

        // Request redraw on main thread
        DispatchQueue.main.async { [weak self] in
            self?.onOutputActivity?()
            self?.onNeedsDisplay?()
            if clearedScrollback {
                self?.onStateChange?()
            }
        }
    }

    // MARK: - Resize

    func resize(rows: Int, cols: Int) {
        let (oldRows, oldCols) = lock.withWriteLock { () -> (Int, Int) in
            let oldRows = model.rows
            let oldCols = model.cols
            if rows != oldRows || cols != oldCols {
                model.resize(newRows: rows, newCols: cols)
            }
            return (oldRows, oldCols)
        }

        if rows != oldRows || cols != oldCols {
            pty.resize(rows: UInt16(rows), cols: UInt16(cols))
        }
    }

    func notifyFocusChanged(_ isFocused: Bool) {
        lock.withWriteLock {
            model.notifyFocusChanged(isFocused)
        }
    }

    // MARK: - Scrollback Navigation

    /// Scroll up (view older content). Returns true if the offset changed.
    @discardableResult
    func scrollUp(lines: Int) -> Bool {
        lock.withWriteLock {
            let maxOffset = scrollback.rowCount
            let newOffset = min(maxOffset, scrollOffset + lines)
            if newOffset != scrollOffset {
                scrollOffset = newOffset
                return true
            }
            return false
        }
    }

    /// Scroll down (view newer content). Returns true if the offset changed.
    @discardableResult
    func scrollDown(lines: Int) -> Bool {
        lock.withWriteLock {
            let newOffset = max(0, scrollOffset - lines)
            if newOffset != scrollOffset {
                scrollOffset = newOffset
                return true
            }
            return false
        }
    }

    /// Set the scroll offset to an absolute value (used by NSScroller drag).
    func setScrollOffset(_ offset: Int) {
        lock.withWriteLock {
            let maxOffset = scrollback.rowCount
            scrollOffset = max(0, min(maxOffset, offset))
        }
    }

    /// Scroll to the very bottom (resume normal operation).
    func scrollToBottom() {
        lock.withWriteLock {
            scrollOffset = 0
        }
    }

    // MARK: - Thread-Safe Model Access

    /// Execute a block with read access to the terminal model.
    func withModel<T>(_ block: (TerminalModel) -> T) -> T {
        lock.withReadLock {
            block(model)
        }
    }

    /// Execute a block with read access to model, scrollback, and scroll state.
    func withViewport<T>(_ block: (TerminalModel, ScrollbackBuffer, Int) -> T) -> T {
        lock.withReadLock {
            block(model, scrollback, scrollOffset)
        }
    }

    func selectedText(for selection: TerminalSelection) -> String {
        lock.withReadLock {
            let rows = visibleRowsLocked()
            return Self.extractText(selection: selection, rows: rows, cols: model.cols)
        }
    }

    func allText() -> String {
        lock.withReadLock {
            var rows: [ViewportRow] = []
            rows.reserveCapacity(scrollback.rowCount + model.rows)
            for row in 0..<scrollback.rowCount {
                rows.append(
                    ViewportRow(
                        cells: scrollback.getRow(at: row) ?? [],
                        isWrapped: scrollback.isRowWrapped(at: row)
                    )
                )
            }
            for row in 0..<model.rows {
                rows.append(
                    ViewportRow(
                        cells: (0..<model.cols).map { model.grid.cell(at: row, col: $0) },
                        isWrapped: model.grid.isWrapped(row)
                    )
                )
            }
            return Self.extractAllText(rows: rows, cols: model.cols)
        }
    }

    func findMatches(for query: String) -> [SearchMatch] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }

        return lock.withReadLock {
            var matches: [SearchMatch] = []
            for row in 0..<scrollback.rowCount {
                if let cells = scrollback.getRow(at: row) {
                    matches.append(contentsOf: Self.findMatches(in: cells, row: row, query: needle))
                }
            }

            for row in 0..<model.rows {
                var cells: [Cell] = []
                cells.reserveCapacity(model.cols)
                for col in 0..<model.cols {
                    cells.append(model.grid.cell(at: row, col: col))
                }
                matches.append(contentsOf: Self.findMatches(in: cells, row: scrollback.rowCount + row, query: needle))
            }

            return matches
        }
    }

    func revealSearchMatch(_ match: SearchMatch) -> TerminalSelection {
        let relativeRow = lock.withWriteLock { () -> Int in
            let scrollbackCount = scrollback.rowCount
            let visibleTop: Int
            if match.absoluteRow < scrollbackCount {
                visibleTop = match.absoluteRow
                scrollOffset = scrollbackCount - visibleTop
            } else {
                visibleTop = scrollbackCount
                scrollOffset = 0
            }
            return max(0, min(model.rows - 1, match.absoluteRow - visibleTop))
        }

        return TerminalSelection(
            anchor: GridPosition(row: relativeRow, col: match.startCol),
            active: GridPosition(row: relativeRow, col: match.endCol),
            mode: .normal
        )
    }

    func detectedLink(at position: GridPosition) -> DetectedLink? {
        lock.withReadLock {
            let rows = visibleRowsLocked()
            guard position.row >= 0, position.row < rows.count else { return nil }

            let row = rows[position.row]
            let projection = Self.projectVisibleText(from: row.cells)
            guard !projection.text.isEmpty,
                  position.col >= 0,
                  let characterIndex = projection.characterIndexByColumn[position.col],
                  let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
                return nil
            }

            let nsText = projection.text as NSString
            let searchRange = NSRange(location: 0, length: nsText.length)
            for match in detector.matches(in: projection.text, options: [], range: searchRange) {
                guard let url = match.url,
                      NSLocationInRange(characterIndex, match.range) else {
                    continue
                }
                let originalText = nsText.substring(with: match.range)

                // Reverse-map NSRange character indices to column positions
                let matchStart = match.range.location
                let matchEnd = matchStart + match.range.length - 1
                guard let startCol = projection.columnByCharacterIndex[matchStart],
                      let endCol = projection.columnByCharacterIndex[matchEnd] else {
                    continue
                }
                return DetectedLink(url: url, originalText: originalText,
                                    startCol: startCol, endCol: endCol)
            }
            return nil
        }
    }

    private func visibleRowsLocked() -> [ViewportRow] {
        let scrollbackCount = scrollback.rowCount
        let firstAbsolute = scrollOffset > 0 ? max(0, scrollbackCount - scrollOffset) : scrollbackCount

        return (0..<model.rows).map { row in
            let absoluteRow = firstAbsolute + row
            if absoluteRow < scrollbackCount {
                return ViewportRow(
                    cells: scrollback.getRow(at: absoluteRow) ?? [],
                    isWrapped: scrollback.isRowWrapped(at: absoluteRow)
                )
            }
            let gridRow = absoluteRow - scrollbackCount
            return ViewportRow(
                cells: (0..<model.cols).map { model.grid.cell(at: gridRow, col: $0) },
                isWrapped: model.grid.isWrapped(gridRow)
            )
        }
    }

    private static func extractText(selection: TerminalSelection, rows: [ViewportRow], cols: Int) -> String {
        guard !selection.isEmpty, !rows.isEmpty else { return "" }
        let start = selection.start
        let end = selection.end
        guard start.row < rows.count else { return "" }

        var result = ""
        switch selection.mode {
        case .normal:
            for rowIndex in start.row...min(end.row, rows.count - 1) {
                let row = rows[rowIndex]
                let columnStart = rowIndex == start.row ? start.col : 0
                let columnEnd = rowIndex == end.row ? end.col : max(cols - 1, 0)
                appendCells(in: row.cells, from: columnStart, through: columnEnd, to: &result)
                if rowIndex < min(end.row, rows.count - 1) {
                    trimTrailingSpaces(from: &result)
                    if !rows[rowIndex + 1].isWrapped {
                        result.append("\n")
                    }
                }
            }
        case .rectangular:
            for rowIndex in start.row...min(end.row, rows.count - 1) {
                let row = rows[rowIndex]
                appendCells(in: row.cells, from: start.col, through: min(end.col, cols - 1), to: &result)
                if rowIndex < min(end.row, rows.count - 1) {
                    trimTrailingSpaces(from: &result)
                    result.append("\n")
                }
            }
        }
        return result
    }

    private static func extractAllText(rows: [ViewportRow], cols: Int) -> String {
        guard !rows.isEmpty else { return "" }
        var result = ""
        for (index, row) in rows.enumerated() {
            appendCells(in: row.cells, from: 0, through: max(cols - 1, 0), to: &result)
            if index < rows.count - 1 {
                trimTrailingSpaces(from: &result)
                if !rows[index + 1].isWrapped {
                    result.append("\n")
                }
            }
        }
        return result
    }

    private static func appendCells(in row: [Cell], from start: Int, through end: Int, to output: inout String) {
        guard start <= end else { return }
        for column in start...end {
            guard column >= 0, column < row.count else { continue }
            let cell = row[column]
            if cell.isWideContinuation { continue }
            if let scalar = Unicode.Scalar(cell.codepoint) {
                output.append(Character(scalar))
            }
        }
    }

    private static func trimTrailingSpaces(from string: inout String) {
        while string.hasSuffix(" ") {
            string.removeLast()
        }
    }

    private static func displayDirectoryName(for path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if expanded == home {
            return "~"
        }
        return URL(fileURLWithPath: expanded).lastPathComponent
    }

    private static func findMatches(in cells: [Cell], row: Int, query: String) -> [SearchMatch] {
        var text = ""
        var columns: [Int] = []
        for (index, cell) in cells.enumerated() {
            if cell.isWideContinuation { continue }
            if let scalar = Unicode.Scalar(cell.codepoint) {
                text.append(Character(scalar))
                columns.append(index)
            }
        }

        let haystack = text.lowercased()
        guard !haystack.isEmpty else { return [] }

        var results: [SearchMatch] = []
        var start = haystack.startIndex
        while let range = haystack.range(of: query, range: start..<haystack.endIndex) {
            let startOffset = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            let endOffset = haystack.distance(from: haystack.startIndex, to: range.upperBound) - 1
            if startOffset < columns.count, endOffset < columns.count {
                results.append(SearchMatch(absoluteRow: row,
                                           startCol: columns[startOffset],
                                           endCol: columns[endOffset]))
            }
            start = range.upperBound
        }
        return results
    }

    private static func projectVisibleText(from cells: [Cell]) -> (text: String, characterIndexByColumn: [Int: Int], columnByCharacterIndex: [Int: Int]) {
        var text = ""
        var colToChar: [Int: Int] = [:]
        var charToCol: [Int: Int] = [:]

        for (column, cell) in cells.enumerated() {
            if cell.isWideContinuation { continue }
            guard let scalar = Unicode.Scalar(cell.codepoint) else { continue }
            // Use UTF-16 offset for NSRange compatibility with NSDataDetector
            let utf16Offset = text.utf16.count
            text.append(Character(scalar))
            colToChar[column] = utf16Offset
            charToCol[utf16Offset] = column
        }

        return (text, colToChar, charToCol)
    }
}

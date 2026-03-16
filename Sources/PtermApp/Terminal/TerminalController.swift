import AppKit
import Foundation
import PtermCore
import Dispatch

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

    struct DetectedImagePlaceholder: Equatable {
        let index: Int
        let originalText: String
        let startCol: Int
        let endCol: Int
    }

    struct SearchMatch: Equatable {
        let absoluteRow: Int
        let startCol: Int
        let endCol: Int
    }

    /// A frozen copy of the current viewport state for benchmarks and diagnostics.
    ///
    /// This snapshot is intentionally broad and includes enough data for
    /// diagnostics that need to inspect the whole viewport source state.
    struct ViewportSnapshot {
        let rows: Int
        let cols: Int
        let cursor: CursorState
        let scrollOffset: Int
        let scrollbackRowCount: Int
        let grid: TerminalGrid
        let scrollbackRows: [[Cell]]
        let scrollbackRowHasData: [Bool]
    }

    struct RenderRowSnapshot {
        let cells: [Cell]
    }

    /// The minimum self-contained state required to render one frame safely.
    ///
    /// The lock protects consistency while we read shared terminal state. Once
    /// this snapshot has been assembled, rendering must not touch `model`,
    /// `scrollback`, or `scrollOffset` again. That lets us release the read lock
    /// before the expensive vertex-building and Metal work starts, while still
    /// guaranteeing that every field below comes from the same logical instant.
    ///
    /// Included on purpose:
    /// - `rows` / `cols`: geometry and selection bounds
    /// - `cursor`: cursor visibility, shape, and position for the same frame
    /// - `scrollOffset`: cursor suppression and viewport mode
    /// - `firstVisibleAbsoluteRow`: maps search matches onto the frozen rows
    /// - `visibleRows`: the exact cells the renderer may inspect
    ///
    /// Omitted on purpose:
    /// - non-visible scrollback/grid rows, because the renderer should not read
    ///   data it cannot draw for the current frame
    struct RenderSnapshot {
        let rows: Int
        let cols: Int
        let cursor: CursorState
        let scrollOffset: Int
        let firstVisibleAbsoluteRow: Int
        let visibleRows: [RenderRowSnapshot]
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

    /// Coalesces bursty PTY-driven callbacks onto a single main-queue hop.
    private let callbackLock = NSLock()
    private let extractionScratchLock = NSLock()
    private let interruptDrainLock = NSLock()
    private var mainCallbacksScheduled = false
    private var pendingNeedsDisplay = false
    private var pendingOutputActivity = false
    private var pendingStateChange = false
    private var interruptDiscardingOutput = false
    private var pendingInterruptDrainCompletion: DispatchWorkItem?
    private var renderContentVersion: UInt64 = 0
    private var outputActivitySuppressedUntilUptime: TimeInterval = 0
    private let scrollbackCompactionLock = NSLock()
    private var pendingScrollbackCompaction: DispatchWorkItem?
    private let ptyResizeLock = NSLock()
    private var pendingPTYResizeWorkItem: DispatchWorkItem?
    private var appliedPTYSize: (rows: Int, cols: Int)?

    /// Decode buffer for UTF-8 -> codepoints.
    /// Starts empty and grows on demand so idle terminals do not pay a
    /// per-controller fixed 64KB tax.
    private var codepointBuffer: [UInt32] = []
    private var textExtractionGridRowBuffer: [Cell] = []
    private var textExtractionScrollbackRowBuffer: [Cell] = []
    private var searchColumnBuffer: [Int] = []
    private var pendingScrollbackRows: [ScrollbackBuffer.BufferedRow] = []
    private var pendingScrollbackRowBufferPool: [[Cell]] = []
    private var isBatchingScrollbackDuringPTYParse = false

    private let termEnv: String
    private let textEncoding: TerminalTextEncoding
    private let shellLaunchOrder: [String]
    private var persistedFontName: String
    private var persistedFontSize: Double
    private let initialDirectory: String
    private let scrollbackPersistenceEnabled: Bool
    private let currentDirectoryProvider: (pid_t) -> String?
    private var parserRequestedScrollbackClear = false
    private var suppressScrollbackClear = false
    private var isShuttingDown = false
    var auditLogger: TerminalAuditLogger?

    private static let minimumCodepointBufferCapacity = 1024
    private static let maxAllTextReserveCapacity = 64 * 1024
    private static let maxSearchReserveCapacity = 4 * 1024
    private static let inputEchoSuppressionInterval: TimeInterval = 0.35
    private static let interruptDrainQuietPeriod: TimeInterval = 0.10
    private static let ptyResizeCoalescingDelay: TimeInterval = 0.05

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

    var thumbnailContentVersion: UInt64 {
        callbackLock.withLock {
            renderContentVersion
        }
    }

    var currentRenderContentVersion: UInt64 {
        callbackLock.withLock {
            renderContentVersion
        }
    }

    var isInInterruptCatchUpMode: Bool {
        false
    }

    var debugCodepointBufferCapacity: Int {
        lock.withReadLock { codepointBuffer.count }
    }

    var debugTextExtractionScratchCapacity: Int {
        extractionScratchLock.withLock {
            textExtractionGridRowBuffer.count + textExtractionScrollbackRowBuffer.count
        }
    }

    var debugSearchScratchCapacity: Int {
        extractionScratchLock.withLock {
            searchColumnBuffer.count
        }
    }

    init(rows: Int, cols: Int, termEnv: String, textEncoding: TerminalTextEncoding,
         shellLaunchOrder: [String] = ShellLaunchConfiguration.default.launchOrder,
         scrollbackInitialCapacity: Int,
         scrollbackMaxCapacity: Int,
         fontName: String,
         fontSize: Double,
         initialDirectory: String? = nil, customTitle: String? = nil,
         workspaceName: String = "Uncategorized", id: UUID = UUID(),
         scrollbackPersistencePath: String? = nil,
         currentDirectoryProvider: @escaping (pid_t) -> String? = { ProcessInspection.currentDirectory(pid: $0) }) {
        self.model = TerminalModel(rows: rows, cols: cols)
        self.pty = PTY()
        self.scrollback = ScrollbackBuffer(
            initialCapacity: scrollbackInitialCapacity,
            maxCapacity: scrollbackMaxCapacity,
            persistentPath: scrollbackPersistencePath
        )
        self.termEnv = termEnv
        self.textEncoding = textEncoding
        self.shellLaunchOrder = ShellLaunchConfiguration.normalizedLaunchOrder(shellLaunchOrder)
        self.textDecoder = TerminalTextDecoder(encoding: textEncoding)
        self.persistedFontName = fontName
        self.persistedFontSize = fontSize
        self.initialDirectory = (initialDirectory as NSString?)?.expandingTildeInPath
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.scrollbackPersistenceEnabled = scrollbackPersistencePath != nil
        self.currentDirectoryProvider = currentDirectoryProvider
        self.customTitle = customTitle
        self.workspaceName = FileNameSanitizer.sanitize(workspaceName, fallback: "Uncategorized")
        self.id = id
        self.currentDirectoryPath = self.initialDirectory
        self.currentDirectory = Self.displayDirectoryName(for: self.initialDirectory)

        // If mmap-backed scrollback already contains data from a previous session,
        // protect it from shell startup clear sequences (e.g. zsh sends \e[3J).
        // This must be set before start() is called so the PTY output handler
        // respects the flag from the very first byte.
        if scrollbackPersistenceEnabled && scrollback.rowCount > 0 {
            suppressScrollbackClear = true
        }

        setupParser()
        setupModelCallbacks()
    }

    deinit {
        cancelPendingPTYResize()
        cancelPendingScrollbackCompaction()
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

        model.onWorkingDirectoryChange = { [weak self] path in
            self?.updateCurrentDirectory(path: path)
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
        model.onScrollOut = { [weak self] cells, isWrapped, encodingHint in
            guard let self = self else { return }
            if self.isBatchingScrollbackDuringPTYParse {
                var reusableCells = self.pendingScrollbackRowBufferPool.popLast() ?? []
                reusableCells.removeAll(keepingCapacity: true)
                if reusableCells.capacity < cells.count {
                    reusableCells.reserveCapacity(cells.count)
                }
                reusableCells.append(contentsOf: cells)
                self.pendingScrollbackRows.append(
                    ScrollbackBuffer.BufferedRow(
                        cells: reusableCells,
                        isWrapped: isWrapped,
                        encodingHint: encodingHint
                    )
                )
            } else {
                self.scrollback.appendRow(cells, isWrapped: isWrapped, encodingHint: encodingHint)

                // If user is scrolled back, increment offset to keep viewport stable
                if self.scrollOffset > 0 {
                    self.scrollOffset += 1
                }
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

        try pty.start(
            rows: UInt16(r),
            cols: UInt16(c),
            termEnv: termEnv,
            initialDirectory: initialDirectory,
            shellLaunchOrder: shellLaunchOrder
        )
        ptyResizeLock.withLock {
            appliedPTYSize = (r, c)
        }
    }

    func stop(waitForExit: Bool = false) {
        cancelPendingPTYResize()
        lock.withWriteLock {
            isShuttingDown = true
            releaseScratchStorageNow()
        }
        pty.stop(waitForExit: waitForExit)
    }

    /// Send SIGTERM and close PTY without blocking. Call awaitExit() later.
    func initiateShutdown() {
        lock.withWriteLock {
            isShuttingDown = true
            releaseScratchStorageNow()
        }
        pty.initiateShutdown()
    }

    /// Block until the child process exits (with SIGKILL escalation).
    func awaitExit() {
        pty.awaitExit()
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
        scheduleMainCallbacks(needsDisplay: true)
    }

    func clearScrollback() {
        cancelPendingScrollbackCompaction()
        lock.withWriteLock {
            scrollback.clear()
            scrollOffset = 0
        }
        scheduleMainCallbacks(needsDisplay: true, stateChange: true)
    }

    func updateCurrentDirectory(path: String) {
        let normalized = Self.displayDirectoryName(for: path)
        let expandedPath = (path as NSString).expandingTildeInPath

        let updateResult = lock.withWriteLock { () -> (titleOverridden: Bool, changed: Bool) in
            let overridden = customTitle != nil
            let changed = currentDirectoryPath != expandedPath || currentDirectory != normalized
            guard changed else {
                return (overridden, false)
            }
            currentDirectoryPath = expandedPath
            currentDirectory = normalized
            return (overridden, true)
        }
        guard updateResult.changed else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?()
            if !updateResult.titleOverridden {
                self?.onTitleChange?(normalized)
            }
        }
    }

    @discardableResult
    func refreshCurrentDirectoryFromShellProcess() -> Bool {
        refreshCurrentDirectory(fromProcessID: processID)
    }

    @discardableResult
    func refreshCurrentDirectory(fromProcessID pid: pid_t?) -> Bool {
        guard let pid, pid > 0, let path = currentDirectoryProvider(pid) else {
            return false
        }
        updateCurrentDirectory(path: path)
        return true
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
        suppressScrollbackClear = false
        let now = ProcessInfo.processInfo.systemUptime
        callbackLock.withLock {
            if Self.shouldSuppressOutputActivity(forInput: data) {
                outputActivitySuppressedUntilUptime = now + Self.inputEchoSuppressionInterval
            } else {
                outputActivitySuppressedUntilUptime = 0
            }
        }
        auditLogger?.recordInput(data)
        pty.write(data)
    }

    /// Send a string as input to the PTY.
    func sendInput(_ string: String) {
        guard let data = textEncoding.encode(string) else { return }
        sendInput(data)
    }

    /// Send an interrupt equivalent to Ctrl+C by injecting the PTY's VINTR byte.
    /// This preserves normal terminal semantics across local shells, SSH, and
    /// other intermediate clients that expect to receive the control character
    /// on stdin rather than a locally-generated Unix signal.
    func performInterrupt() {
        performInterrupt(controlCharacter: 0x03)
    }

    func performInterrupt(controlCharacter: UInt8) {
        callbackLock.withLock {
            interruptDiscardingOutput = true
            outputActivitySuppressedUntilUptime = 0
        }
        scheduleInterruptDrainCompletion()
        sendControlCharacter(controlCharacter)
    }

    private func sendControlCharacter(_ controlCharacter: UInt8) {
        let data = Data([controlCharacter])
        suppressScrollbackClear = false
        auditLogger?.recordInput(data)
        pty.writeControlCharacter(controlCharacter)
    }

    // MARK: - PTY Output Processing

    /// Handle raw bytes from PTY output.
    /// Called on the PTY read thread - must be thread-safe.
    /// The entire decode + parse pipeline runs under lock to ensure
    /// decoder and parser state are never accessed concurrently.
    private func handlePTYOutput(_ data: Data) {
        let shouldDiscardInterruptOutput = callbackLock.withLock {
            interruptDiscardingOutput
        }
        if shouldDiscardInterruptOutput {
            scheduleInterruptDrainCompletion()
            return
        }

        processPTYOutput(data, recordAudit: true)
    }

    private func processPTYOutput(_ data: Data, recordAudit: Bool) {
        guard !data.isEmpty else { return }
        cancelPendingScrollbackCompaction()
        if recordAudit {
            auditLogger?.recordOutput(data)
        }
        var clearedScrollback = false
        var didMutateDisplay = false
        data.withUnsafeBytes { rawPtr in
            guard let ptr = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            let count = rawPtr.count

            lock.withWriteLock {
                isBatchingScrollbackDuringPTYParse = true
                defer {
                    if !pendingScrollbackRows.isEmpty {
                        recyclePendingScrollbackRows()
                    }
                    isBatchingScrollbackDuringPTYParse = false
                }
                let input = UnsafeBufferPointer(start: ptr, count: count)
                let remainingInput: UnsafeBufferPointer<UInt8>
                if canUseDirectASCIIGroundFastPath(input) {
                    let consumed = model.consumeGroundASCIIBytesFastPathPrefix(input)
                    if consumed > 0 {
                        didMutateDisplay = true
                    }
                    remainingInput = UnsafeBufferPointer(
                        start: ptr.advanced(by: consumed),
                        count: count - consumed
                    )
                } else {
                    remainingInput = input
                }

                if !remainingInput.isEmpty {
                    ensureCodepointBufferCapacity(requiredCount: remainingInput.count)
                    let cpCount = textDecoder.decode(remainingInput, into: &codepointBuffer)

                    // Feed codepoints to VT parser (which updates the model)
                    if cpCount > 0 {
                        codepointBuffer.withUnsafeBufferPointer { buffer in
                            let decoded = UnsafeBufferPointer(start: buffer.baseAddress, count: cpCount)
                            if parser.state == VT_STATE_GROUND {
                                let consumed = model.consumeGroundFastPathPrefix(decoded)
                                if consumed < cpCount {
                                    vt_parser_feed(&parser, buffer.baseAddress!.advanced(by: consumed), cpCount - consumed)
                                }
                            } else {
                                vt_parser_feed(&parser, codepointBuffer, cpCount)
                            }
                        }
                        didMutateDisplay = true
                    }
                }

                if parserRequestedScrollbackClear {
                    if suppressScrollbackClear ||
                       (scrollbackPersistenceEnabled && isShuttingDown) {
                        parserRequestedScrollbackClear = false
                    } else {
                        recyclePendingScrollbackRows()
                        scrollback.clear()
                        scrollOffset = 0
                        parserRequestedScrollbackClear = false
                        clearedScrollback = true
                        didMutateDisplay = true
                    }
                }

                if !pendingScrollbackRows.isEmpty {
                    scrollback.appendRows(pendingScrollbackRows)
                    if scrollOffset > 0 {
                        scrollOffset += pendingScrollbackRows.count
                    }
                    recyclePendingScrollbackRows()
                }
            }
        }

        guard didMutateDisplay || clearedScrollback else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let shouldReportOutputActivity = callbackLock.withLock {
            now >= outputActivitySuppressedUntilUptime
        }

        scheduleMainCallbacks(
            needsDisplay: true,
            outputActivity: shouldReportOutputActivity,
            stateChange: clearedScrollback
        )
        scheduleScrollbackCompaction()
    }

    private func canUseDirectASCIIGroundFastPath(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard textEncoding == .utf8,
              textDecoder.canDecodeDirectASCII,
              parser.state == VT_STATE_GROUND,
              model.canUseASCIIGroundFastPath
        else {
            return false
        }

        return true
    }

    private func recyclePendingScrollbackRows() {
        guard !pendingScrollbackRows.isEmpty else { return }
        pendingScrollbackRowBufferPool.reserveCapacity(
            pendingScrollbackRowBufferPool.count + pendingScrollbackRows.count
        )
        while let row = pendingScrollbackRows.popLast() {
            pendingScrollbackRowBufferPool.append(row.cells)
        }
    }

    // MARK: - Resize

    func resize(rows: Int, cols: Int) {
        let (oldRows, oldCols) = lock.withWriteLock { () -> (Int, Int) in
            let oldRows = model.rows
            let oldCols = model.cols
            if rows != oldRows || cols != oldCols {
                model.resize(newRows: rows, newCols: cols)
                // After resize, snap to the latest content so the user sees
                // the current terminal output, not stale scrollback.
                scrollOffset = 0
            }
            return (oldRows, oldCols)
        }

        if rows != oldRows || cols != oldCols {
            scheduleCoalescedPTYResize(rows: rows, cols: cols)
            scheduleMainCallbacks(needsDisplay: true, stateChange: true)
        }
    }

    func notifyCurrentSizeChanged() {
        cancelPendingPTYResize()
        let currentSize = lock.withReadLock {
            (rows: model.rows, cols: model.cols)
        }
        guard currentSize.rows > 0, currentSize.cols > 0 else { return }
        pty.resize(rows: UInt16(currentSize.rows), cols: UInt16(currentSize.cols))
        ptyResizeLock.withLock {
            appliedPTYSize = currentSize
        }
        scheduleMainCallbacks(needsDisplay: true)
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
        let changed = lock.withWriteLock {
            let maxOffset = scrollback.rowCount
            let newOffset = min(maxOffset, scrollOffset + lines)
            if newOffset != scrollOffset {
                scrollOffset = newOffset
                return true
            }
            return false
        }
        if changed {
            scheduleMainCallbacks(needsDisplay: true)
        }
        return changed
    }

    /// Scroll down (view newer content). Returns true if the offset changed.
    @discardableResult
    func scrollDown(lines: Int) -> Bool {
        let changed = lock.withWriteLock {
            let newOffset = max(0, scrollOffset - lines)
            if newOffset != scrollOffset {
                scrollOffset = newOffset
                return true
            }
            return false
        }
        if changed {
            scheduleMainCallbacks(needsDisplay: true)
        }
        return changed
    }

    /// Set the scroll offset to an absolute value (used by NSScroller drag).
    func setScrollOffset(_ offset: Int) {
        let changed = lock.withWriteLock {
            let maxOffset = scrollback.rowCount
            let newOffset = max(0, min(maxOffset, offset))
            guard newOffset != scrollOffset else { return false }
            scrollOffset = newOffset
            return true
        }
        if changed {
            scheduleMainCallbacks(needsDisplay: true)
        }
    }

    /// Scroll to the very bottom (resume normal operation).
    func scrollToBottom() {
        let changed = lock.withWriteLock {
            guard scrollOffset != 0 else { return false }
            scrollOffset = 0
            return true
        }
        if changed {
            scheduleMainCallbacks(needsDisplay: true)
        }
    }

    func scrollToTop() {
        let changed = lock.withWriteLock {
            let target = scrollback.rowCount
            guard scrollOffset != target else { return false }
            scrollOffset = target
            return true
        }
        if changed {
            scheduleMainCallbacks(needsDisplay: true)
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

    func snapshotViewport() -> ViewportSnapshot {
        lock.withReadLock {
            let rows = model.rows
            let cols = model.cols
            let scrollbackRowCount = scrollback.rowCount
            let offset = scrollOffset
            let grid = model.grid.snapshot()

            var scrollbackRows: [[Cell]] = []
            var scrollbackRowHasData: [Bool] = []
            if offset > 0 {
                scrollbackRows = Array(repeating: [], count: rows)
                scrollbackRowHasData = Array(repeating: false, count: rows)
                let firstAbsolute = max(0, scrollbackRowCount - offset)
                for row in 0..<rows {
                    let absoluteRow = firstAbsolute + row
                    guard absoluteRow >= 0, absoluteRow < scrollbackRowCount else { continue }
                    var rowBuffer: [Cell] = []
                    scrollbackRowHasData[row] = scrollback.getRow(at: absoluteRow, into: &rowBuffer)
                    scrollbackRows[row] = rowBuffer
                }
            }

            return ViewportSnapshot(
                rows: rows,
                cols: cols,
                cursor: model.cursor,
                scrollOffset: offset,
                scrollbackRowCount: scrollbackRowCount,
                grid: grid,
                scrollbackRows: scrollbackRows,
                scrollbackRowHasData: scrollbackRowHasData
            )
        }
    }

    func captureRenderSnapshot() -> RenderSnapshot {
        lock.withReadLock {
            let rows = model.rows
            let cols = model.cols
            let cursor = model.cursor
            let offset = scrollOffset
            let visibleRows = visibleRowsLocked()
            let firstVisibleAbsoluteRow = offset > 0
                ? max(0, scrollback.rowCount - offset)
                : scrollback.rowCount

            let renderRows = visibleRows.map { row in
                RenderRowSnapshot(cells: row.cells)
            }

            return RenderSnapshot(
                rows: rows,
                cols: cols,
                cursor: cursor,
                scrollOffset: offset,
                firstVisibleAbsoluteRow: firstVisibleAbsoluteRow,
                visibleRows: renderRows
            )
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
            let totalRows = scrollback.rowCount + model.rows
            guard totalRows > 0 else { return "" }

            return extractionScratchLock.withLock {
                var result = ""
                result.reserveCapacity(Self.suggestedAllTextReserveCapacity(totalRows: totalRows, cols: model.cols))
                textExtractionGridRowBuffer.reserveCapacity(model.cols)
                textExtractionScrollbackRowBuffer.reserveCapacity(model.cols)

                for absoluteRow in 0..<totalRows {
                    let isScrollbackRow = absoluteRow < scrollback.rowCount
                    let cells: [Cell]
                    if isScrollbackRow {
                        _ = scrollback.getRow(at: absoluteRow, into: &textExtractionScrollbackRowBuffer)
                        cells = textExtractionScrollbackRowBuffer
                    } else {
                        let gridRow = absoluteRow - scrollback.rowCount
                        textExtractionGridRowBuffer.removeAll(keepingCapacity: true)
                        textExtractionGridRowBuffer.append(contentsOf: model.grid.rowCells(gridRow))
                        cells = textExtractionGridRowBuffer
                    }

                    Self.appendCells(in: cells, from: 0, through: max(model.cols - 1, 0), to: &result)

                    if absoluteRow < totalRows - 1 {
                        Self.trimTrailingSpaces(from: &result)
                        let nextIsWrapped: Bool
                        if absoluteRow + 1 < scrollback.rowCount {
                            nextIsWrapped = scrollback.isRowWrapped(at: absoluteRow + 1)
                        } else if absoluteRow + 1 < totalRows {
                            let nextGridRow = absoluteRow + 1 - scrollback.rowCount
                            nextIsWrapped = model.grid.isWrapped(nextGridRow)
                        } else {
                            nextIsWrapped = false
                        }
                        if !nextIsWrapped {
                            result.append("\n")
                        }
                    }
                }

                return result
            }
        }
    }

    func findMatches(for query: String) -> [SearchMatch] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }

        return lock.withReadLock {
            extractionScratchLock.withLock {
                var matches: [SearchMatch] = []
                matches.reserveCapacity(Self.suggestedSearchReserveCapacity(scrollbackRows: scrollback.rowCount))
                textExtractionScrollbackRowBuffer.reserveCapacity(model.cols)
                searchColumnBuffer.reserveCapacity(model.cols)
                for row in 0..<scrollback.rowCount {
                    if scrollback.getRow(at: row, into: &textExtractionScrollbackRowBuffer) {
                        Self.appendMatches(
                            in: textExtractionScrollbackRowBuffer,
                            row: row,
                            query: needle,
                            columnsBuffer: &searchColumnBuffer,
                            to: &matches
                        )
                    }
                }

                textExtractionGridRowBuffer.reserveCapacity(model.cols)
                for row in 0..<model.rows {
                    textExtractionGridRowBuffer.removeAll(keepingCapacity: true)
                    for col in 0..<model.cols {
                        textExtractionGridRowBuffer.append(model.grid.cell(at: row, col: col))
                    }
                    Self.appendMatches(
                        in: textExtractionGridRowBuffer,
                        row: scrollback.rowCount + row,
                        query: needle,
                        columnsBuffer: &searchColumnBuffer,
                        to: &matches
                    )
                }

                return matches
            }
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

    func detectedImagePlaceholder(at position: GridPosition) -> DetectedImagePlaceholder? {
        lock.withReadLock {
            let rows = visibleRowsLocked()
            guard position.row >= 0, position.row < rows.count else { return nil }

            let row = rows[position.row]
            let projection = Self.projectVisibleText(from: row.cells)
            guard !projection.text.isEmpty,
                  position.col >= 0,
                  let characterIndex = projection.characterIndexByColumn[position.col] else {
                return nil
            }

            let text = projection.text as NSString
            let searchRange = NSRange(location: 0, length: text.length)
            let regex = Self.imagePlaceholderRegex
            let matches = regex.matches(in: projection.text, options: [], range: searchRange)
            for match in matches {
                guard match.numberOfRanges >= 2,
                      NSLocationInRange(characterIndex, match.range),
                      let range = Range(match.range(at: 1), in: projection.text),
                      let index = Int(projection.text[range]) else {
                    continue
                }
                let matchStart = match.range.location
                let matchEnd = matchStart + match.range.length - 1
                guard let startCol = projection.columnByCharacterIndex[matchStart],
                      let endCol = projection.columnByCharacterIndex[matchEnd] else {
                    continue
                }
                return DetectedImagePlaceholder(
                    index: index,
                    originalText: text.substring(with: match.range),
                    startCol: startCol,
                    endCol: endCol
                )
            }
            return nil
        }
    }

    private func visibleRowsLocked() -> [ViewportRow] {
        let scrollbackCount = scrollback.rowCount
        let firstAbsolute = scrollOffset > 0 ? max(0, scrollbackCount - scrollOffset) : scrollbackCount

        var rows: [ViewportRow] = []
        rows.reserveCapacity(model.rows)
        for row in 0..<model.rows {
            let absoluteRow = firstAbsolute + row
            if absoluteRow < scrollbackCount {
                rows.append(ViewportRow(
                    cells: scrollback.getRow(at: absoluteRow) ?? [],
                    isWrapped: scrollback.isRowWrapped(at: absoluteRow)
                ))
                continue
            }
            let gridRow = absoluteRow - scrollbackCount
            var cells: [Cell] = []
            cells.reserveCapacity(model.cols)
            for col in 0..<model.cols {
                cells.append(model.grid.cell(at: gridRow, col: col))
            }
            rows.append(ViewportRow(cells: cells, isWrapped: model.grid.isWrapped(gridRow)))
        }
        return rows
    }

    private func scheduleMainCallbacks(
        needsDisplay: Bool = false,
        outputActivity: Bool = false,
        stateChange: Bool = false
    ) {
        let shouldSchedule = callbackLock.withLock {
            if needsDisplay {
                renderContentVersion &+= 1
                pendingNeedsDisplay = true
            }
            pendingOutputActivity = pendingOutputActivity || outputActivity
            pendingStateChange = pendingStateChange || stateChange
            if mainCallbacksScheduled {
                return false
            }
            mainCallbacksScheduled = true
            return true
        }

        guard shouldSchedule else { return }

        DispatchQueue.main.async { [weak self] in
            self?.flushScheduledCallbacks()
        }
    }

    private func flushScheduledCallbacks() {
        let callbacks = callbackLock.withLock { () -> (Bool, Bool, Bool) in
            let callbacks = (pendingOutputActivity, pendingNeedsDisplay, pendingStateChange)
            pendingOutputActivity = false
            pendingNeedsDisplay = false
            pendingStateChange = false
            mainCallbacksScheduled = false
            return callbacks
        }

        if callbacks.0 {
            onOutputActivity?()
        }
        if callbacks.1 {
            onNeedsDisplay?()
        }
        if callbacks.2 {
            onStateChange?()
        }
    }

    private func scheduleInterruptDrainCompletion() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.completeInterruptDrainIfNeeded()
        }

        interruptDrainLock.withLock {
            pendingInterruptDrainCompletion?.cancel()
            pendingInterruptDrainCompletion = workItem
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.interruptDrainQuietPeriod,
            execute: workItem
        )
    }

    private func completeInterruptDrainIfNeeded() {
        interruptDrainLock.withLock {
            pendingInterruptDrainCompletion = nil
        }

        callbackLock.withLock {
            guard interruptDiscardingOutput else { return }
            interruptDiscardingOutput = false
        }
    }

    static func shouldSuppressOutputActivity(forInput data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return !data.contains(0x0A) && !data.contains(0x0D)
    }

    private func scheduleScrollbackCompaction() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.performIdleScrollbackCompaction()
        }

        scrollbackCompactionLock.withLock {
            pendingScrollbackCompaction?.cancel()
            pendingScrollbackCompaction = workItem
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func cancelPendingScrollbackCompaction() {
        scrollbackCompactionLock.withLock {
            pendingScrollbackCompaction?.cancel()
            pendingScrollbackCompaction = nil
        }
    }

    @discardableResult
    private func performIdleScrollbackCompaction() -> Bool {
        scrollbackCompactionLock.withLock {
            pendingScrollbackCompaction = nil
        }
        return lock.withWriteLock {
            let didCompact = scrollback.compactIfUnderutilized()
            shrinkIdleCodepointBufferIfNeeded()
            shrinkIdleExtractionScratchIfNeeded()
            return didCompact
        }
    }

    @discardableResult
    func debugCompactScrollbackNow() -> Bool {
        cancelPendingScrollbackCompaction()
        return performIdleScrollbackCompaction()
    }

    func debugPrimeCodepointBufferCapacity(_ requiredCount: Int) {
        lock.withWriteLock {
            ensureCodepointBufferCapacity(requiredCount: requiredCount)
        }
    }

    func debugProcessPTYOutputForTesting(_ data: Data, recordAudit: Bool = false) {
        processPTYOutput(data, recordAudit: recordAudit)
    }

    func debugMeasureWriteLockContentionForTesting(readHoldNanoseconds: UInt64) -> UInt64 {
        let writerReady = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var waitNanoseconds: UInt64 = 0

        lock.withReadLock {
            DispatchQueue.global(qos: .userInitiated).async {
                writerReady.signal()
                let start = ContinuousClock.now
                self.lock.withWriteLock { }
                let duration = start.duration(to: .now)
                resultLock.lock()
                waitNanoseconds = Self.nanoseconds(for: duration)
                resultLock.unlock()
                writerFinished.signal()
            }

            writerReady.wait()
            if readHoldNanoseconds > 0 {
                let seconds = Double(readHoldNanoseconds) / 1_000_000_000
                Thread.sleep(forTimeInterval: seconds)
            }
        }

        writerFinished.wait()
        resultLock.lock()
        let measured = waitNanoseconds
        resultLock.unlock()
        return measured
    }

    private func ensureCodepointBufferCapacity(requiredCount: Int) {
        guard requiredCount > codepointBuffer.count else { return }
        let minimum = max(Self.minimumCodepointBufferCapacity, requiredCount)
        var newCapacity = max(1, codepointBuffer.count)
        while newCapacity < minimum {
            newCapacity <<= 1
        }
        codepointBuffer = [UInt32](repeating: 0, count: newCapacity)
    }

    private func shrinkIdleCodepointBufferIfNeeded() {
        guard !codepointBuffer.isEmpty else { return }
        codepointBuffer.removeAll(keepingCapacity: false)
    }

    private func scheduleCoalescedPTYResize(rows: Int, cols: Int) {
        cancelPendingPTYResize()
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.ptyResizeLock.withLock {
                let alreadyApplied = self.appliedPTYSize?.rows == rows &&
                    self.appliedPTYSize?.cols == cols
                if !alreadyApplied {
                    self.pty.resize(rows: UInt16(rows), cols: UInt16(cols))
                    self.appliedPTYSize = (rows, cols)
                }
                if self.pendingPTYResizeWorkItem === workItem {
                    self.pendingPTYResizeWorkItem = nil
                }
            }
        }
        guard let workItem else { return }
        ptyResizeLock.withLock {
            pendingPTYResizeWorkItem = workItem
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.ptyResizeCoalescingDelay,
            execute: workItem
        )
    }

    private func cancelPendingPTYResize() {
        let pending = ptyResizeLock.withLock { () -> DispatchWorkItem? in
            let workItem = pendingPTYResizeWorkItem
            pendingPTYResizeWorkItem = nil
            return workItem
        }
        pending?.cancel()
    }

    private func shrinkIdleExtractionScratchIfNeeded() {
        extractionScratchLock.withLock {
            textExtractionGridRowBuffer.removeAll(keepingCapacity: false)
            textExtractionScrollbackRowBuffer.removeAll(keepingCapacity: false)
            searchColumnBuffer.removeAll(keepingCapacity: false)
        }
    }

    private func releaseScratchStorageNow() {
        codepointBuffer.removeAll(keepingCapacity: false)
        shrinkIdleExtractionScratchIfNeeded()
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

    private static func suggestedAllTextReserveCapacity(totalRows: Int, cols: Int) -> Int {
        let estimated = max(totalRows * max(cols, 1), cols)
        return min(maxAllTextReserveCapacity, estimated)
    }

    private static func suggestedSearchReserveCapacity(scrollbackRows: Int) -> Int {
        min(maxSearchReserveCapacity, max(16, scrollbackRows / 4))
    }

    private static func nanoseconds(for duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = UInt64(max(components.seconds, 0))
        let attoseconds = UInt64(max(components.attoseconds, 0))
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
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
        var results: [SearchMatch] = []
        var columnsBuffer: [Int] = []
        appendMatches(in: cells, row: row, query: query, columnsBuffer: &columnsBuffer, to: &results)
        return results
    }

    private static func appendMatches(
        in cells: [Cell],
        row: Int,
        query: String,
        columnsBuffer: inout [Int],
        to results: inout [SearchMatch]
    ) {
        var text = ""
        text.reserveCapacity(cells.count)
        columnsBuffer.removeAll(keepingCapacity: true)
        columnsBuffer.reserveCapacity(cells.count)
        for (index, cell) in cells.enumerated() {
            if cell.isWideContinuation { continue }
            if let scalar = Unicode.Scalar(cell.codepoint) {
                text.append(Character(scalar))
                columnsBuffer.append(index)
            }
        }

        let haystack = text.lowercased()
        guard !haystack.isEmpty else { return }

        var start = haystack.startIndex
        while let range = haystack.range(of: query, range: start..<haystack.endIndex) {
            let startOffset = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            let endOffset = haystack.distance(from: haystack.startIndex, to: range.upperBound) - 1
            if startOffset < columnsBuffer.count, endOffset < columnsBuffer.count {
                results.append(SearchMatch(absoluteRow: row,
                                           startCol: columnsBuffer[startOffset],
                                           endCol: columnsBuffer[endOffset]))
            }
            start = range.upperBound
        }
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

    static func debugSuggestedAllTextReserveCapacity(totalRows: Int, cols: Int) -> Int {
        suggestedAllTextReserveCapacity(totalRows: totalRows, cols: cols)
    }

    static func debugSuggestedSearchReserveCapacity(scrollbackRows: Int) -> Int {
        suggestedSearchReserveCapacity(scrollbackRows: scrollbackRows)
    }

    private static let imagePlaceholderRegex = try! NSRegularExpression(pattern: #"\[Image #([0-9]+)\]"#)
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

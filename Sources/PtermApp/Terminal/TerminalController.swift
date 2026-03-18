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
    private static let kittyImageProcessingConcurrency = min(
        max(ProcessInfo.processInfo.activeProcessorCount / 2, 2),
        8
    )
    private static let kittyImageProcessingQueue = DispatchQueue(
        label: "com.tranworks.pterm.kitty-image-processing",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let kittyImageProcessingSemaphore = DispatchSemaphore(
        value: kittyImageProcessingConcurrency
    )

    private struct ViewportRow {
        let cells: [Cell]
        let isWrapped: Bool
        let lineAttribute: TerminalLineAttribute
    }

    struct DetectedLink {
        let url: URL
        let originalText: String
        let startCol: Int
        let endCol: Int
    }

    struct DetectedImagePlaceholder: Equatable {
        let ownerID: UUID?
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
        let lineAttribute: TerminalLineAttribute
        let isWrapped: Bool
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
        let contentVersion: UInt64
        let rows: Int
        let cols: Int
        let cursor: CursorState
        let reverseVideo: Bool
        let scrollOffset: Int
        let scrollbackRowCount: Int
        let firstVisibleAbsoluteRow: Int
        let ownerID: UUID
        let hasInlineImages: Bool
        let inlineImagePlacements: [TerminalInlineImagePlacement]
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

    /// Whether this terminal is transient and must never be restored from session persistence.
    let isTransient: Bool

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
    var onRenderingSuppressedChange: ((Bool) -> Void)?

    /// Callback when terminal exits
    var onExit: (() -> Void)?

    /// Callback when title changes
    var onTitleChange: ((String) -> Void)?
    var onStateChange: (() -> Void)?
    var onInlineImageReachabilityChange: ((UUID, Set<Int>) -> Void)?

    /// Coalesces bursty PTY-driven callbacks onto a single main-queue hop.
    private let callbackLock = NSLock()
    private let renderSnapshotCacheLock = NSLock()
    private let extractionScratchLock = NSLock()
    private let interruptDrainLock = NSLock()
    private var mainCallbacksScheduled = false
    private var pendingNeedsDisplay = false
    private var pendingOutputActivity = false
    private var pendingStateChange = false
    private var inlineImageReachabilityReconcileScheduled = false
    private var lastKnownInlineImageReachabilityWasNonEmpty = false
    private var terminalRenderingSuppressed = false
    private var pendingRenderingSuppressedChanges: [Bool] = []
    private var interruptDiscardingOutput = false
    private var pendingInterruptDrainCompletion: DispatchWorkItem?
    private var renderContentVersion: UInt64 = 0
    private var cachedRenderSnapshot: RenderSnapshot?
    private var cachedRenderSnapshotVersion: UInt64 = 0
    private var lastOutputDate: Date?
    private var outputActivitySuppressedUntilUptime: TimeInterval = 0
    private let scrollbackCompactionLock = NSLock()
    private var pendingScrollbackCompaction: DispatchSourceTimer?
    private var scrollbackCompactionArmed = false
    private var lastScrollbackActivityUptime: TimeInterval = 0
    private let ptyResizeLock = NSLock()
    private var pendingPTYResizeWorkItem: DispatchWorkItem?
    private var appliedPTYSize: (rows: Int, cols: Int)?
    private var isBatchingParserScrollOut = false
    private var pendingParserScrollOutRows: [ScrollbackBuffer.BufferedRow] = []
    private var pendingParserScrollOffsetDelta = 0
    private var pendingGroundBytes: [UInt8] = []
    private var pendingKittyGraphicsBytes: [UInt8] = []
    private var pendingKittyGraphicsSearchStart = 0
    private struct KittyGraphicsConsumeResult {
        let consumed: Int
        let deferredJob: TerminalModel.DeferredKittyImagePayloadJob?
    }

    /// Decode buffer for UTF-8 -> codepoints.
    /// Starts empty and grows on demand so idle terminals do not pay a
    /// per-controller fixed 64KB tax.
    private var codepointBuffer: [UInt32] = []
    private var textExtractionGridRowBuffer: [Cell] = []
    private var textExtractionScrollbackRowBuffer: [Cell] = []
    private var searchColumnBuffer: [Int] = []
    private let termEnv: String
    private let textEncoding: TerminalTextEncoding
    private let shellLaunchOrder: [String]
    private var persistedFontName: String
    private var persistedFontSize: Double
    private let initialDirectory: String
    private let executablePath: String?
    private let executableArguments: [String]
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
    private static let scrollbackCompactionDelay: TimeInterval = 1.0
    private static let scrollbackCompactionQueue = DispatchQueue(
        label: "com.pterm.scrollback.compaction",
        qos: .utility
    )

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

    var screenRevision: UInt64 {
        callbackLock.withLock {
            renderContentVersion
        }
    }

    var lastOutputAt: Date? {
        callbackLock.withLock {
            lastOutputDate
        }
    }

    var foregroundProcessName: String? {
        let pid = foregroundProcessID ?? processID
        guard pid > 0 else { return nil }
        return ProcessInspection.processName(pid: pid)
    }

    var isRenderingSuppressed: Bool {
        lock.withReadLock { terminalRenderingSuppressed }
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
         initialDirectory: String? = nil,
         executablePath: String? = nil,
         executableArguments: [String] = [],
         isTransient: Bool = false,
         customTitle: String? = nil,
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
        self.executablePath = executablePath
        self.executableArguments = executableArguments
        self.isTransient = isTransient
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
        invalidateScrollbackCompactionTimer()
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
            self.pty.writeResponse(data)
        }

        model.onResponseData = { [weak self] data in
            guard let self = self else { return }
            self.pty.writeResponse(data)
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

        model.onPendingUpdateModeChange = { [weak self] suppressed in
            guard let self = self else { return }
            if self.terminalRenderingSuppressed != suppressed {
                self.terminalRenderingSuppressed = suppressed
                self.pendingRenderingSuppressedChanges.append(suppressed)
            }
        }

        model.onKittyImagePayload = { [weak self] index, data, format, pixelWidth, pixelHeight, columns, rows in
            Self.kittyImageProcessingSemaphore.wait()
            Self.kittyImageProcessingQueue.async {
                defer { Self.kittyImageProcessingSemaphore.signal() }
                autoreleasepool {
                    guard let self else { return }
                    try? PastedImageRegistry.shared.registerTransient(
                        imageData: data,
                        format: format,
                        placeholderIndex: index,
                        ownerID: self.id,
                        pixelWidth: pixelWidth,
                        pixelHeight: pixelHeight,
                        columns: columns,
                        rows: rows
                    )
                    self.scheduleInlineImageReachabilityReconcile(force: true)
                    self.scheduleMainCallbacks(needsDisplay: true)
                }
            }
        }

        // Wire scrollback: when a line scrolls off the top, store it
        model.onScrollOut = { [weak self] row in
            guard let self = self else { return }
            if self.model.isAlternateScreen {
                return
            }
            if self.isBatchingParserScrollOut {
                self.pendingParserScrollOutRows.append(row)
                if self.scrollOffset > 0 {
                    self.pendingParserScrollOffsetDelta += 1
                }
            } else {
                self.scrollback.appendRow(row)

                // If user is scrolled back, increment offset to keep viewport stable
                if self.scrollOffset > 0 {
                    self.scrollOffset += 1
                }
            }
        }
    }

    private func liveInlineImagePlaceholderIndicesLocked() -> Set<Int> {
        var ids = model.grid.liveInlineImageIDs()
        ids.formUnion(scrollback.liveInlineImageIDs())
        return ids
    }

    private func reconcileInlineImageReachability() {
        let liveIndices = lock.withReadLock {
            liveInlineImagePlaceholderIndicesLocked()
        }
        callbackLock.withLock {
            lastKnownInlineImageReachabilityWasNonEmpty = !liveIndices.isEmpty
        }
        onInlineImageReachabilityChange?(id, liveIndices)
    }

    private func scheduleInlineImageReachabilityReconcile(force: Bool = false) {
        if force {
            reconcileInlineImageReachability()
            return
        }

        let gridCurrentlyContainsInlineImages: Bool = {
            return lock.withReadLock {
                !model.grid.liveInlineImageIDs().isEmpty
            }
        }()
        let shouldSchedule = callbackLock.withLock { () -> Bool in
            if !force && !lastKnownInlineImageReachabilityWasNonEmpty && !gridCurrentlyContainsInlineImages {
                return false
            }
            if inlineImageReachabilityReconcileScheduled {
                return false
            }
            inlineImageReachabilityReconcileScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callbackLock.withLock {
                self.inlineImageReachabilityReconcileScheduled = false
            }
            self.reconcileInlineImageReachability()
        }
    }

    // MARK: - Start / Stop

    func start() throws {
        pty.onOutputBytes = { [weak self] bytes in
            self?.handlePTYOutput(bytes)
        }

        pty.onExit = { [weak self] in
            self?.auditLogger?.flush()
            self?.reconcileInlineImageReachability()
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
            shellLaunchOrder: shellLaunchOrder,
            executablePath: executablePath,
            arguments: executableArguments
        )
        ptyResizeLock.withLock {
            appliedPTYSize = (r, c)
        }
    }

    func stop(waitForExit: Bool = false) {
        cancelPendingPTYResize()
        cancelPendingScrollbackCompaction()
        lock.withWriteLock {
            isShuttingDown = true
            scrollback.flushPendingRows()
            releaseScratchStorageNow()
        }
        pty.stop(waitForExit: waitForExit)
    }

    /// Send SIGTERM and close PTY without blocking. Call awaitExit() later.
    func initiateShutdown() {
        lock.withWriteLock {
            isShuttingDown = true
            scrollback.flushPendingRows()
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
        reconcileInlineImageReachability()
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

    /// Sequence emitted for an Enter/Return keypress, honoring ANSI newline mode.
    func newlineKeyInput() -> String {
        withModel { $0.newLineMode ? "\r\n" : "\r" }
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
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            handlePTYOutput(UnsafeBufferPointer(start: baseAddress, count: rawBuffer.count))
        }
    }

    private func handlePTYOutput(_ data: UnsafeBufferPointer<UInt8>) {
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
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            processPTYOutput(
                UnsafeBufferPointer(start: baseAddress, count: rawBuffer.count),
                recordAudit: recordAudit
            )
        }
    }

    private func processPTYOutput(_ data: UnsafeBufferPointer<UInt8>, recordAudit: Bool) {
        guard !data.isEmpty else { return }
        callbackLock.withLock {
            lastOutputDate = Date()
        }
        if recordAudit, let auditLogger {
            auditLogger.recordOutput(Data(bytes: data.baseAddress!, count: data.count))
        }
        var clearedScrollback = false
        var didMutateDisplay = false
        var renderingSuppressed = false
        var renderingSuppressedChanges: [Bool] = []
        var startedRenderingSuppressed = false
        var shouldScheduleScrollbackCompaction = true
        var deferredKittyImageJobs: [TerminalModel.DeferredKittyImagePayloadJob] = []
        let ptr = data.baseAddress!
        let count = data.count

        lock.withWriteLock {
            startedRenderingSuppressed = terminalRenderingSuppressed
            beginParserScrollOutBatch()
            defer { endParserScrollOutBatch() }

            let workingBufferStorage: [UInt8]?
            if pendingGroundBytes.isEmpty {
                workingBufferStorage = nil
            } else {
                var combined = pendingGroundBytes
                combined.reserveCapacity(combined.count + count)
                combined.append(contentsOf: data)
                pendingGroundBytes.removeAll(keepingCapacity: true)
                workingBufferStorage = combined
            }

            let processInput: (UnsafeBufferPointer<UInt8>) -> Void = { [self] workingInput in
                var fastPathPointer = workingInput.baseAddress!
                var fastPathRemainingCount = workingInput.count

                while fastPathRemainingCount > 0 {
                    let input = UnsafeBufferPointer(start: fastPathPointer, count: fastPathRemainingCount)

                    if let kittyGraphics = self.consumeKittyGraphicsPayloadPrefix(input),
                       kittyGraphics.consumed > 0 {
                        if let deferredJob = kittyGraphics.deferredJob {
                            deferredKittyImageJobs.append(deferredJob)
                        }
                        didMutateDisplay = true
                        fastPathPointer = fastPathPointer.advanced(by: kittyGraphics.consumed)
                        fastPathRemainingCount -= kittyGraphics.consumed
                        continue
                    }

                    if self.canUseDirectASCIIGroundFastPath(input) {
                        let consumed = self.model.consumeGroundASCIIBytesFastPathPrefix(input)
                        if consumed > 0 {
                            didMutateDisplay = true
                            fastPathPointer = fastPathPointer.advanced(by: consumed)
                            fastPathRemainingCount -= consumed
                            continue
                        }
                    }

                    if self.canUseDirectUTF8WideGroundFastPath(input) {
                        let consumed = self.consumeDirectUTF8WideGroundFastPath(input)
                        if consumed > 0 {
                            didMutateDisplay = true
                            fastPathPointer = fastPathPointer.advanced(by: consumed)
                            fastPathRemainingCount -= consumed
                            continue
                        }
                    }

                    let ignoredStringBytes = vt_parser_consume_ascii_ignored_string_fast_path(
                        &self.parser,
                        fastPathPointer,
                        fastPathRemainingCount
                    )
                    if ignoredStringBytes > 0 {
                        fastPathPointer = fastPathPointer.advanced(by: ignoredStringBytes)
                        fastPathRemainingCount -= ignoredStringBytes
                        continue
                    }

                    break
                }

                let remainingInput = UnsafeBufferPointer(start: fastPathPointer, count: fastPathRemainingCount)
                if self.parser.state == VT_STATE_GROUND,
                   self.shouldDeferIncompleteGroundSequence(remainingInput) {
                    self.pendingGroundBytes = Array(remainingInput)
                    return
                }

                if !remainingInput.isEmpty {
                    self.ensureCodepointBufferCapacity(requiredCount: remainingInput.count)
                    let cpCount = self.textDecoder.decode(remainingInput, into: &self.codepointBuffer)

                    if cpCount > 0 {
                        self.codepointBuffer.withUnsafeBufferPointer { buffer in
                            let decoded = UnsafeBufferPointer(start: buffer.baseAddress, count: cpCount)
                            if self.parser.state == VT_STATE_GROUND {
                                let consumed = self.model.consumeGroundFastPathPrefix(decoded)
                                if consumed < cpCount {
                                    vt_parser_feed(&self.parser, buffer.baseAddress!.advanced(by: consumed), cpCount - consumed)
                                }
                            } else {
                                vt_parser_feed(&self.parser, self.codepointBuffer, cpCount)
                            }
                        }
                        didMutateDisplay = true
                    }
                }
            }

            if let workingBufferStorage {
                workingBufferStorage.withUnsafeBufferPointer(processInput)
            } else {
                processInput(UnsafeBufferPointer(start: ptr, count: count))
            }

            if parserRequestedScrollbackClear {
                if suppressScrollbackClear ||
                   (scrollbackPersistenceEnabled && isShuttingDown) {
                    parserRequestedScrollbackClear = false
                } else {
                    discardPendingParserScrollOutBatch()
                    scrollback.clear()
                    scrollOffset = 0
                    parserRequestedScrollbackClear = false
                    clearedScrollback = true
                    didMutateDisplay = true
                }
            }

            flushPendingParserScrollOutBatch()
            renderingSuppressed = terminalRenderingSuppressed
            renderingSuppressedChanges = pendingRenderingSuppressedChanges
            pendingRenderingSuppressedChanges.removeAll(keepingCapacity: true)
            shouldScheduleScrollbackCompaction = !model.isAlternateScreen || scrollback.rowCount > 0
                if didMutateDisplay {
                    renderSnapshotCacheLock.withLock {
                        cachedRenderSnapshotVersion = 0
                    }
                }
        }

        if !deferredKittyImageJobs.isEmpty {
            for job in deferredKittyImageJobs {
                model.executeDeferredKittyImagePayload(job)
            }
        }

        if !renderingSuppressedChanges.isEmpty {
            let pendingUpdateAnalysis = Self.analyzePendingUpdateSequences(in: data)
            let now = ProcessInfo.processInfo.systemUptime
            let shouldReportOutputActivity = callbackLock.withLock {
                now >= outputActivitySuppressedUntilUptime
            }

            if renderingSuppressedChanges == [false, true],
               startedRenderingSuppressed,
               (didMutateDisplay || clearedScrollback),
               pendingUpdateAnalysis.hasRenderableContentBeforeDisable {
                scheduleInterleavedRenderingSuppressionDisplay(
                    outputActivity: shouldReportOutputActivity,
                    stateChange: clearedScrollback,
                    endingSuppressed: true
                )
                if shouldScheduleScrollbackCompaction {
                    scheduleScrollbackCompaction()
                }
                return
            }

            if renderingSuppressedChanges == [true],
               (didMutateDisplay || clearedScrollback),
               pendingUpdateAnalysis.hasRenderableContentBeforeEnable {
                scheduleMainCallbacks(
                    needsDisplay: true,
                    outputActivity: shouldReportOutputActivity,
                    stateChange: clearedScrollback
                )
                dispatchRenderingSuppressionChanges(renderingSuppressedChanges)
                if shouldScheduleScrollbackCompaction {
                    scheduleScrollbackCompaction()
                }
                return
            }

            dispatchRenderingSuppressionChanges(renderingSuppressedChanges)
        }

        guard didMutateDisplay || clearedScrollback else {
            if shouldScheduleScrollbackCompaction {
                scheduleScrollbackCompaction()
            }
            return
        }

        if didMutateDisplay || clearedScrollback {
            scheduleInlineImageReachabilityReconcile(force: clearedScrollback)
        }

        let now = ProcessInfo.processInfo.systemUptime
        let shouldReportOutputActivity = callbackLock.withLock {
            now >= outputActivitySuppressedUntilUptime
        }
        let shouldRequestDisplay = !renderingSuppressed
        let shouldReportOutputActivityNow = shouldRequestDisplay && shouldReportOutputActivity

        scheduleMainCallbacks(
            needsDisplay: shouldRequestDisplay,
            outputActivity: shouldReportOutputActivityNow,
            stateChange: clearedScrollback
        )
        if shouldScheduleScrollbackCompaction {
            scheduleScrollbackCompaction()
        }
    }

    private func shouldDeferIncompleteGroundSequence(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !bytes.isEmpty,
              bytes.count <= 64,
              bytes[0] == 0x1B
        else {
            return false
        }

        guard bytes.count >= 2 else { return true }
        let introducer = bytes[1]
        switch introducer {
        case UInt8(ascii: "["):
            guard bytes.count >= 3 else { return true }
            for index in 2..<bytes.count where bytes[index] >= 0x40 && bytes[index] <= 0x7E {
                return false
            }
            return true

        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            var index = 2
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x07 {
                    return false
                }
                if byte == 0x1B {
                    guard index + 1 < bytes.count else { return true }
                    if bytes[index + 1] == UInt8(ascii: "\\") {
                        return false
                    }
                }
                index += 1
            }
            return true

        case 0x37, 0x38, 0x44, 0x45, 0x48, 0x4D, 0x3D, 0x3E, 0x63:
            return false

        default:
            return bytes.count == 1
        }
    }

    private struct PendingUpdateSequenceAnalysis {
        var hasRenderableContentBeforeEnable = false
        var hasRenderableContentBeforeDisable = false
    }

    private static func analyzePendingUpdateSequences(
        in data: UnsafeBufferPointer<UInt8>
    ) -> PendingUpdateSequenceAnalysis {
        guard let bytes = data.baseAddress, data.count >= 8 else {
            return PendingUpdateSequenceAnalysis()
        }
        var result = PendingUpdateSequenceAnalysis()
        var segmentHasRenderableContent = false
        var index = 0

        while index < data.count {
            if bytes[index] == 0x1B, index <= data.count - 8,
               bytes[index + 1] == 0x5B,
               bytes[index + 2] == 0x3F,
               bytes[index + 3] == 0x32,
               bytes[index + 4] == 0x30,
               bytes[index + 5] == 0x32,
               bytes[index + 6] == 0x36 {
                if bytes[index + 7] == 0x68 {
                    if segmentHasRenderableContent {
                        result.hasRenderableContentBeforeEnable = true
                    }
                    segmentHasRenderableContent = false
                    index += 8
                    continue
                }
                if bytes[index + 7] == 0x6C {
                    if segmentHasRenderableContent {
                        result.hasRenderableContentBeforeDisable = true
                    }
                    segmentHasRenderableContent = false
                    index += 8
                    continue
                }
            }

            if !segmentHasRenderableContent, Self.isRenderableByte(bytes[index]) {
                segmentHasRenderableContent = true
                if result.hasRenderableContentBeforeEnable && result.hasRenderableContentBeforeDisable {
                    return result
                }
            }
            index += 1
        }

        return result
    }

    private static func isRenderableByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D:
            return true
        case 0x20...0x7E, 0x80...0xFF:
            return true
        default:
            return false
        }
    }

    private func dispatchRenderingSuppressionChanges(_ changes: [Bool]) {
        guard !changes.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for change in changes {
                self.onRenderingSuppressedChange?(change)
            }
        }
    }

    private func scheduleInterleavedRenderingSuppressionDisplay(
        outputActivity: Bool,
        stateChange: Bool,
        endingSuppressed: Bool
    ) {
        callbackLock.withLock {
            renderContentVersion &+= 1
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onRenderingSuppressedChange?(false)
            if outputActivity {
                self.onOutputActivity?()
            }
            self.onNeedsDisplay?()
            if stateChange {
                self.onStateChange?()
            }
            if endingSuppressed {
                self.onRenderingSuppressedChange?(true)
            }
        }
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

    private func canUseDirectUTF8WideGroundFastPath(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !bytes.isEmpty,
              textEncoding == .utf8,
              textDecoder.canDecodeDirectASCII,
              parser.state == VT_STATE_GROUND,
              model.canUseKnownWideUTF8GroundFastPath
        else {
            return false
        }

        return true
    }

    private func consumeKittyGraphicsPayloadPrefix(_ bytes: UnsafeBufferPointer<UInt8>) -> KittyGraphicsConsumeResult? {
        guard textEncoding == .utf8,
              parser.state == VT_STATE_GROUND
        else {
            return nil
        }

        if pendingKittyGraphicsBytes.isEmpty {
            if bytes.count == 2,
               bytes[0] == 0x1B,
               bytes[1] == UInt8(ascii: "_") {
                pendingKittyGraphicsBytes.append(contentsOf: bytes)
                pendingKittyGraphicsSearchStart = max(pendingKittyGraphicsBytes.count - 1, 0)
                return KittyGraphicsConsumeResult(consumed: bytes.count, deferredJob: nil)
            }
            guard bytes.count >= 3,
                  bytes[0] == 0x1B,
                  bytes[1] == UInt8(ascii: "_"),
                  bytes[2] == UInt8(ascii: "G")
            else {
                return nil
            }
        }

        if pendingKittyGraphicsBytes.isEmpty {
            if let terminatorOffset = asciiSTTerminatorOffset(in: bytes) {
                let payloadBytes = UnsafeBufferPointer(start: bytes.baseAddress!.advanced(by: 2), count: terminatorOffset - 2)
                let deferredJob = model.handleKittyGraphicsAPCPayload(payloadBytes)
                return KittyGraphicsConsumeResult(consumed: terminatorOffset + 2, deferredJob: deferredJob)
            }
            pendingKittyGraphicsBytes.append(contentsOf: bytes)
            pendingKittyGraphicsSearchStart = max(pendingKittyGraphicsBytes.count - 1, 0)
            return KittyGraphicsConsumeResult(consumed: bytes.count, deferredJob: nil)
        }

        let existingCount = pendingKittyGraphicsBytes.count
        pendingKittyGraphicsBytes.append(contentsOf: bytes)
        let searchStart = max(0, min(pendingKittyGraphicsSearchStart, max(pendingKittyGraphicsBytes.count - 1, 0)))
        if let relativeTerminatorOffset = pendingKittyGraphicsBytes.withUnsafeBufferPointer({ buffer -> Int? in
            guard searchStart < buffer.count else { return nil }
            let slice = UnsafeBufferPointer(
                start: buffer.baseAddress!.advanced(by: searchStart),
                count: buffer.count - searchStart
            )
            return asciiSTTerminatorOffset(in: slice)
        }) {
            let terminatorOffset = searchStart + relativeTerminatorOffset
            let payloadStart = 2
            let payloadCount = terminatorOffset - payloadStart
            var deferredJob: TerminalModel.DeferredKittyImagePayloadJob?
            if payloadCount > 0 {
                let payloadSlice = pendingKittyGraphicsBytes[payloadStart..<(payloadStart + payloadCount)]
                payloadSlice.withUnsafeBufferPointer { buffer in
                    deferredJob = model.handleKittyGraphicsAPCPayload(buffer)
                }
            }
            let consumedFromPendingChunk = max(0, min(bytes.count, terminatorOffset + 2 - existingCount))
            pendingKittyGraphicsBytes.removeAll(keepingCapacity: true)
            pendingKittyGraphicsSearchStart = 0
            return KittyGraphicsConsumeResult(consumed: consumedFromPendingChunk, deferredJob: deferredJob)
        }
        pendingKittyGraphicsSearchStart = max(pendingKittyGraphicsBytes.count - 1, 0)
        return KittyGraphicsConsumeResult(consumed: bytes.count, deferredJob: nil)
    }

    private func asciiSTTerminatorOffset(in bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        guard let base = bytes.baseAddress, bytes.count >= 2 else { return nil }
        for index in 0..<(bytes.count - 1) where base[index] == 0x1B && base[index + 1] == UInt8(ascii: "\\") {
            return index
        }
        return nil
    }

    private func asciiSTTerminatorOffset(in bytes: [UInt8]) -> Int? {
        bytes.withUnsafeBufferPointer(asciiSTTerminatorOffset)
    }

    private func consumeDirectUTF8WideGroundFastPath(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else { return 0 }

        var index = 0
        while index < bytes.count {
            let asciiInput = UnsafeBufferPointer(start: baseAddress.advanced(by: index), count: bytes.count - index)
            let asciiConsumed = model.consumeGroundASCIIBytesFastPathPrefix(asciiInput)
            if asciiConsumed > 0 {
                index += asciiConsumed
                continue
            }

            let remainingCount = bytes.count - index
            ensureCodepointBufferCapacity(requiredCount: remainingCount / 3)

            var bytesConsumed = 0
            let decodedCount = codepointBuffer.withUnsafeMutableBufferPointer { buffer -> Int in
                guard let outputBase = buffer.baseAddress else { return 0 }
                return Int(
                    utf8_decoder_decode_common_wide_three_byte_prefix(
                        baseAddress.advanced(by: index),
                        remainingCount,
                        outputBase,
                        buffer.count,
                        &bytesConsumed
                    )
                )
            }

            if decodedCount > 0 {
                codepointBuffer.withUnsafeBufferPointer { buffer in
                    model.handleKnownDoubleWidthCodepointRun(
                        UnsafeBufferPointer(start: buffer.baseAddress, count: decodedCount)
                    )
                }
                index += bytesConsumed
                continue
            }

            if model.consumeGroundExecuteFastPath(UInt32(baseAddress[index])) {
                index += 1
                continue
            }

            break
        }

        return index
    }

    private func beginParserScrollOutBatch() {
        precondition(!isBatchingParserScrollOut, "Parser scroll-out batching must not be nested")
        isBatchingParserScrollOut = true
        pendingParserScrollOutRows.removeAll(keepingCapacity: true)
        pendingParserScrollOffsetDelta = 0
    }

    private func endParserScrollOutBatch() {
        isBatchingParserScrollOut = false
        pendingParserScrollOutRows.removeAll(keepingCapacity: true)
        pendingParserScrollOffsetDelta = 0
    }

    private func discardPendingParserScrollOutBatch() {
        pendingParserScrollOutRows.removeAll(keepingCapacity: true)
        pendingParserScrollOffsetDelta = 0
    }

    private func flushPendingParserScrollOutBatch() {
        guard !pendingParserScrollOutRows.isEmpty else { return }
        scrollback.appendRows(pendingParserScrollOutRows)
        if scrollOffset > 0 {
            scrollOffset += pendingParserScrollOffsetDelta
        }
        pendingParserScrollOutRows.removeAll(keepingCapacity: true)
        pendingParserScrollOffsetDelta = 0
    }

    // MARK: - Resize

    func resize(rows: Int, cols: Int) {
        let (oldRows, oldCols) = lock.withWriteLock { () -> (Int, Int) in
            let oldRows = model.rows
            let oldCols = model.cols
            if rows != oldRows || cols != oldCols {
                // Presentation transitions can trigger multiple resizes while the
                // same completed output is being reflowed across views. Commit any
                // pending recent scrollback rows before mutating the grid so the
                // resize operates on a stable history boundary instead of mixing
                // transient recent rows with newly trimmed rows from the resize.
                scrollback.flushPendingRows()
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
            let dimensions = visibleGridDimensionsLocked()
            let rows = dimensions.rows
            let cols = dimensions.cols
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
        let expectedVersion = currentRenderContentVersion
        if let cached = renderSnapshotCacheLock.withLock({
            cachedRenderSnapshotVersion == expectedVersion ? cachedRenderSnapshot : nil
        }) {
            return cached
        }
        let snapshot = lock.withReadLock {
            buildRenderSnapshotLocked()
        }
        renderSnapshotCacheLock.withLock {
            cachedRenderSnapshot = snapshot
            cachedRenderSnapshotVersion = snapshot.contentVersion
        }
        return snapshot
    }

    private func buildRenderSnapshotLocked() -> RenderSnapshot {
        let dimensions = visibleGridDimensionsLocked()
        let rows = dimensions.rows
        let cols = dimensions.cols
        let cursor = model.cursor
        let reverseVideo = model.reverseVideoEnabled
        let offset = scrollOffset
        let scrollbackCount = scrollback.rowCount
        let firstVisibleAbsoluteRow = offset > 0
            ? max(0, scrollbackCount - offset)
            : scrollbackCount

        var renderRows: [RenderRowSnapshot] = []
        renderRows.reserveCapacity(rows)
        var scrollbackRowBuffer: [Cell] = []
        scrollbackRowBuffer.reserveCapacity(cols)
        for row in 0..<rows {
            let absoluteRow = firstVisibleAbsoluteRow + row
            if absoluteRow < scrollbackCount {
                scrollbackRowBuffer.removeAll(keepingCapacity: true)
                _ = scrollback.getRow(at: absoluteRow, into: &scrollbackRowBuffer)
                renderRows.append(
                    RenderRowSnapshot(
                        cells: scrollbackRowBuffer,
                        lineAttribute: .singleWidth,
                        isWrapped: scrollback.isRowWrapped(at: absoluteRow)
                    )
                )
                continue
            }

            let gridRow = absoluteRow - scrollbackCount
            let compactCells = Array(model.grid.rowCells(gridRow))
            let cells = compactCells.isEmpty ? Array(repeating: .empty, count: cols) : compactCells
            renderRows.append(
                RenderRowSnapshot(
                    cells: cells,
                    lineAttribute: model.grid.lineAttribute(at: gridRow),
                    isWrapped: model.grid.isWrapped(gridRow)
                )
            )
        }
        let hasInlineImages = renderRows.contains { row in
            row.cells.contains { $0.hasInlineImage }
        }
        let inlineImagePlacements = hasInlineImages
            ? TerminalInlineImageSupport.detectPlacements(in: renderRows, ownerID: id)
            : []

        let contentVersion = currentRenderContentVersion
        return RenderSnapshot(
            contentVersion: contentVersion,
            rows: rows,
            cols: cols,
            cursor: cursor,
            reverseVideo: reverseVideo,
            scrollOffset: offset,
            scrollbackRowCount: scrollbackCount,
            firstVisibleAbsoluteRow: firstVisibleAbsoluteRow,
            ownerID: id,
            hasInlineImages: hasInlineImages,
            inlineImagePlacements: inlineImagePlacements,
            visibleRows: renderRows
        )
    }

    func captureRenderSnapshotIfAvailable() -> RenderSnapshot? {
        let expectedVersion = currentRenderContentVersion
        let cachedState = renderSnapshotCacheLock.withLock {
            (cachedRenderSnapshot, cachedRenderSnapshotVersion)
        }
        if let cached = cachedState.0, cachedState.1 == expectedVersion {
            return cached
        }
        let snapshot = lock.tryWithReadLock {
            buildRenderSnapshotLocked()
        }
        if let snapshot {
            renderSnapshotCacheLock.withLock {
                cachedRenderSnapshot = snapshot
                cachedRenderSnapshotVersion = snapshot.contentVersion
            }
            return snapshot
        }
        return cachedState.0
    }

    func selectedText(for selection: TerminalSelection) -> String {
        lock.withReadLock {
            let dimensions = visibleGridDimensionsLocked()
            let rows = visibleRowsLocked()
            return Self.extractText(selection: selection, rows: rows, cols: dimensions.cols)
        }
    }

    func allText() -> String {
        lock.withReadLock {
            let dimensions = visibleGridDimensionsLocked()
            let totalRows = scrollback.rowCount + dimensions.rows
            guard totalRows > 0 else { return "" }

            return extractionScratchLock.withLock {
                var result = ""
                result.reserveCapacity(Self.suggestedAllTextReserveCapacity(totalRows: totalRows, cols: dimensions.cols))
                textExtractionGridRowBuffer.reserveCapacity(dimensions.cols)
                textExtractionScrollbackRowBuffer.reserveCapacity(dimensions.cols)

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

                    let maxColumn = max(dimensions.cols - 1, 0)
                    if absoluteRow < totalRows - 1 {
                        let nextIsWrapped: Bool
                        if absoluteRow + 1 < scrollback.rowCount {
                            nextIsWrapped = scrollback.isRowWrapped(at: absoluteRow + 1)
                        } else if absoluteRow + 1 < totalRows {
                            let nextGridRow = absoluteRow + 1 - scrollback.rowCount
                            nextIsWrapped = model.grid.isWrapped(nextGridRow)
                        } else {
                            nextIsWrapped = false
                        }
                        if let textEndColumn = Self.lastNonSpaceColumn(in: cells, through: maxColumn) {
                            Self.appendCells(in: cells, from: 0, through: textEndColumn, to: &result)
                        }
                        if !nextIsWrapped {
                            result.append("\n")
                        }
                    } else {
                        Self.appendCells(in: cells, from: 0, through: maxColumn, to: &result)
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
            let dimensions = visibleGridDimensionsLocked()
            return extractionScratchLock.withLock {
                var matches: [SearchMatch] = []
                matches.reserveCapacity(Self.suggestedSearchReserveCapacity(scrollbackRows: scrollback.rowCount))
                textExtractionScrollbackRowBuffer.reserveCapacity(dimensions.cols)
                searchColumnBuffer.reserveCapacity(dimensions.cols)
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

                textExtractionGridRowBuffer.reserveCapacity(dimensions.cols)
                for row in 0..<dimensions.rows {
                    textExtractionGridRowBuffer.removeAll(keepingCapacity: true)
                    for col in 0..<dimensions.cols {
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
            let dimensions = visibleGridDimensionsLocked()
            let scrollbackCount = scrollback.rowCount
            let visibleTop: Int
            if match.absoluteRow < scrollbackCount {
                visibleTop = match.absoluteRow
                scrollOffset = scrollbackCount - visibleTop
            } else {
                visibleTop = scrollbackCount
                scrollOffset = 0
            }
            return max(0, min(dimensions.rows - 1, match.absoluteRow - visibleTop))
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
            let visibleRows = visibleRowsLocked().map { row in
                RenderRowSnapshot(
                    cells: row.cells,
                    lineAttribute: row.lineAttribute,
                    isWrapped: row.isWrapped
                )
            }
            for placement in TerminalInlineImageSupport.detectPlacements(in: visibleRows, ownerID: id)
            where placement.row == position.row && position.col >= placement.startCol && position.col <= placement.endCol {
                return DetectedImagePlaceholder(
                    ownerID: placement.ownerID,
                    index: placement.index,
                    originalText: placement.originalText,
                    startCol: placement.startCol,
                    endCol: placement.endCol
                )
            }
            return nil
        }
    }

    private func visibleRowsLocked() -> [ViewportRow] {
        let dimensions = visibleGridDimensionsLocked()
        let scrollbackCount = scrollback.rowCount
        let firstAbsolute = scrollOffset > 0 ? max(0, scrollbackCount - scrollOffset) : scrollbackCount

        var rows: [ViewportRow] = []
        rows.reserveCapacity(dimensions.rows)
        for row in 0..<dimensions.rows {
            let absoluteRow = firstAbsolute + row
            if absoluteRow < scrollbackCount {
                rows.append(ViewportRow(
                    cells: scrollback.getRow(at: absoluteRow) ?? [],
                    isWrapped: scrollback.isRowWrapped(at: absoluteRow),
                    lineAttribute: .singleWidth
                ))
                continue
            }
            let gridRow = absoluteRow - scrollbackCount
            var cells: [Cell] = []
            cells.reserveCapacity(dimensions.cols)
            for col in 0..<dimensions.cols {
                cells.append(model.grid.cell(at: gridRow, col: col))
            }
            rows.append(
                ViewportRow(
                    cells: cells,
                    isWrapped: model.grid.isWrapped(gridRow),
                    lineAttribute: model.grid.lineAttribute(at: gridRow)
                )
            )
        }
        return rows
    }

    private func visibleGridDimensionsLocked() -> (rows: Int, cols: Int) {
        let dimensions = model.grid.readableDimensions()
        if model.rows != dimensions.rows || model.cols != dimensions.cols {
            model.reconcileCachedDimensionsWithActiveGrid()
        }
        return dimensions
    }

    private func scheduleMainCallbacks(
        needsDisplay: Bool = false,
        outputActivity: Bool = false,
        stateChange: Bool = false
    ) {
        let shouldSchedule = callbackLock.withLock {
            let wantsNeedsDisplay = needsDisplay && onNeedsDisplay != nil
            let wantsOutputActivity = outputActivity && onOutputActivity != nil
            let wantsStateChange = stateChange && onStateChange != nil
            if needsDisplay {
                renderContentVersion &+= 1
            }
            guard wantsNeedsDisplay || wantsOutputActivity || wantsStateChange else {
                return false
            }
            pendingNeedsDisplay = pendingNeedsDisplay || wantsNeedsDisplay
            pendingOutputActivity = pendingOutputActivity || wantsOutputActivity
            pendingStateChange = pendingStateChange || wantsStateChange
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
        let now = ProcessInfo.processInfo.systemUptime
        let timerToSchedule = scrollbackCompactionLock.withLock { () -> DispatchSourceTimer? in
            lastScrollbackActivityUptime = now
            let timer: DispatchSourceTimer
            if let pendingScrollbackCompaction {
                timer = pendingScrollbackCompaction
            } else {
                let created = DispatchSource.makeTimerSource(queue: Self.scrollbackCompactionQueue)
                created.setEventHandler { [weak self] in
                    self?.handleScrollbackCompactionTimerFired()
                }
                pendingScrollbackCompaction = created
                created.resume()
                timer = created
            }
            guard !scrollbackCompactionArmed else {
                return nil
            }
            scrollbackCompactionArmed = true
            return timer
        }
        timerToSchedule?.schedule(
            deadline: .now() + Self.scrollbackCompactionDelay,
            leeway: .milliseconds(50)
        )
    }

    private func cancelPendingScrollbackCompaction() {
        let timer = scrollbackCompactionLock.withLock { () -> DispatchSourceTimer? in
            scrollbackCompactionArmed = false
            return pendingScrollbackCompaction
        }
        timer?.schedule(deadline: .distantFuture)
    }

    private func invalidateScrollbackCompactionTimer() {
        let timer = scrollbackCompactionLock.withLock { () -> DispatchSourceTimer? in
            let timer = pendingScrollbackCompaction
            pendingScrollbackCompaction = nil
            return timer
        }
        timer?.setEventHandler {}
        timer?.cancel()
    }

    @discardableResult
    private func performIdleScrollbackCompaction() -> Bool {
        let didCompact = lock.withWriteLock {
            let didCompact = scrollback.compactIfUnderutilized()
            shrinkIdleCodepointBufferIfNeeded()
            shrinkIdleExtractionScratchIfNeeded()
            return didCompact
        }
        reconcileInlineImageReachability()
        return didCompact
    }

    private func handleScrollbackCompactionTimerFired() {
        enum TimerAction {
            case reschedule(TimeInterval, DispatchSourceTimer)
            case compact
            case none
        }

        let action = scrollbackCompactionLock.withLock { () -> TimerAction in
            guard let timer = pendingScrollbackCompaction, scrollbackCompactionArmed else {
                return .none
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - lastScrollbackActivityUptime
            let remaining = Self.scrollbackCompactionDelay - elapsed
            if remaining > 0 {
                return .reschedule(remaining, timer)
            }
            scrollbackCompactionArmed = false
            return .compact
        }

        switch action {
        case .reschedule(let delay, let timer):
            timer.schedule(deadline: .now() + delay, leeway: .milliseconds(50))
        case .compact:
            _ = performIdleScrollbackCompaction()
        case .none:
            break
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

    func debugAppendScrollbackRowForTesting(
        _ cells: ArraySlice<Cell>,
        isWrapped: Bool,
        encodingHint: ScrollbackBuffer.RowEncodingHint = .unknown
    ) {
        lock.withWriteLock {
            scrollback.appendRow(cells, isWrapped: isWrapped, encodingHint: encodingHint)
        }
    }

    func debugReconcileInlineImageReachabilityForTesting() {
        reconcileInlineImageReachability()
    }

    func debugSimulateProcessExitForTesting() {
        auditLogger?.flush()
        reconcileInlineImageReachability()
        onExit?()
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

    private static func lastNonSpaceColumn(in row: [Cell], through end: Int) -> Int? {
        guard !row.isEmpty, end >= 0 else { return nil }
        var column = min(end, row.count - 1)
        while column >= 0 {
            let cell = row[column]
            if cell.isWideContinuation || cell.codepoint == 0x20 {
                column -= 1
                continue
            }
            return column
        }
        return nil
    }

    private static func appendCells(in row: [Cell], from start: Int, through end: Int, to output: inout String) {
        guard start <= end else { return }
        for column in start...end {
            guard column >= 0, column < row.count else { continue }
            let cell = row[column]
            if cell.isWideContinuation || cell.hasInlineImage { continue }
            output.append(cell.renderedString())
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
            if cell.isWideContinuation || cell.hasInlineImage { continue }
            let rendered = cell.renderedString()
            if !rendered.isEmpty {
                text.append(rendered)
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
            if cell.isWideContinuation || cell.hasInlineImage { continue }
            let rendered = cell.renderedString()
            guard !rendered.isEmpty else { continue }
            // Use UTF-16 offset for NSRange compatibility with NSDataDetector
            let utf16Offset = text.utf16.count
            text.append(rendered)
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
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

import AppKit
import MetalKit
import QuartzCore

private extension String {
    func appendLine(to url: URL) throws {
        let data = Data(utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}

final class PtermWindow: NSWindow {
    var onBackToIntegratedShortcut: (() -> Void)?
    var onInterruptShortcut: (() -> Bool)?
    var onCommandModifierChange: ((Bool) -> Void)?
    private static let supportedModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isBackToIntegratedShortcut(event) {
            onBackToIntegratedShortcut?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            onCommandModifierChange?(event.modifierFlags.intersection(Self.supportedModifierMask).contains(.command))
        }
        if event.type == .keyDown, isInterruptShortcut(event), onInterruptShortcut?() == true {
            return
        }
        if event.type == .keyDown, isBackToIntegratedShortcut(event) {
            onBackToIntegratedShortcut?()
            return
        }
        super.sendEvent(event)
    }

    private func isBackToIntegratedShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(Self.supportedModifierMask)
        return modifiers == [.command] && event.keyCode == 50  // Cmd+` (backtick)
    }

    private func isInterruptShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(Self.supportedModifierMask)
        guard modifiers == [.control],
              let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }
        return characters == "c"
    }
}

/// Application delegate for pterm.
///
/// Manages the single application window, terminal lifecycle,
/// view switching between integrated view and focused view,
/// and top-level keyboard shortcuts.
final class AppDelegate: NSObject, NSApplicationDelegate {
    struct MCPTerminalObservation: Equatable {
        let terminalID: UUID
        let foregroundProcessName: String?
        let screenRevision: UInt64
        let lastOutputAt: Date?
    }

    struct MCPTerminalWaitCondition: Equatable {
        let terminalID: UUID
        let foregroundProcessName: String?
        let screenRevisionGreaterThan: UInt64?
        let idleForMilliseconds: Int?
        let timeoutMilliseconds: Int

        init(arguments: [String: Any]) throws {
            guard let rawTerminalID = arguments["terminal_id"] as? String,
                  let terminalID = UUID(uuidString: rawTerminalID) else {
                throw MCPServerError.invalidRequest
            }

            let idleForMilliseconds = arguments["idle_for_ms"] as? Int
            let timeoutMilliseconds = max(arguments["timeout_ms"] as? Int ?? 5_000, 1)
            let screenRevisionGreaterThan: UInt64?
            if let value = arguments["screen_revision_gt"] as? UInt64 {
                screenRevisionGreaterThan = value
            } else if let value = arguments["screen_revision_gt"] as? Int, value >= 0 {
                screenRevisionGreaterThan = UInt64(value)
            } else {
                screenRevisionGreaterThan = nil
            }

            self.terminalID = terminalID
            self.foregroundProcessName = arguments["foreground_process_name"] as? String
            self.screenRevisionGreaterThan = screenRevisionGreaterThan
            self.idleForMilliseconds = idleForMilliseconds
            self.timeoutMilliseconds = timeoutMilliseconds
        }

        func isSatisfied(by observation: MCPTerminalObservation, now: Date = Date()) -> Bool {
            guard observation.terminalID == terminalID else { return false }
            if let foregroundProcessName,
               observation.foregroundProcessName != foregroundProcessName {
                return false
            }
            if let screenRevisionGreaterThan,
               observation.screenRevision <= screenRevisionGreaterThan {
                return false
            }
            if let idleForMilliseconds {
                guard let lastOutputAt = observation.lastOutputAt else { return false }
                let idleDuration = now.timeIntervalSince(lastOutputAt) * 1000
                if idleDuration < Double(idleForMilliseconds) {
                    return false
                }
            }
            return true
        }
    }

    private enum Layout {
        static let statusBarHeight: CGFloat = 24
        static let searchBarHeight: CGFloat = 40
    }

    private enum SessionPersistence {
        static let debounceInterval: TimeInterval = 0.15
        static let queueLabel = "com.pterm.session-persistence"
    }

    /// The single application window
    private var window: NSWindow!

    private var config: PtermConfig = .default

    private struct ConfigFileSignature: Equatable {
        let exists: Bool
        let fileSize: UInt64
        let modificationDate: Date?

        static func capture(at url: URL) -> ConfigFileSignature {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return ConfigFileSignature(exists: false, fileSize: 0, modificationDate: nil)
            }
            let sizeNumber = attributes[.size] as? NSNumber
            return ConfigFileSignature(
                exists: true,
                fileSize: sizeNumber?.uint64Value ?? 0,
                modificationDate: attributes[.modificationDate] as? Date
            )
        }
    }

    private var statusBarView: StatusBarView!
    private var windowBackgroundGlassView: NSView?
    private var windowRootContentView: NSView!
    private var windowHostedContentView: NSView!
    private var windowPresentationHostView: NSView!
    private var configWatchSource: DispatchSourceFileSystemObject?
    private var pendingConfigReload: DispatchWorkItem?
    private var lastLoadedConfigSignature = ConfigFileSignature.capture(at: PtermDirectories.config)
    private var backShortcutMonitor: Any?
    private var commandIdentityModifierMonitor: Any?
    private var commandIdentityShortcutLocalMonitor: Any?
    private var commandIdentityShortcutGlobalMonitor: Any?
    private var commandIdentityHeaderSuppressedUntilCommandRelease = false
    private var titlebarBackButton: NSButton?

    private var metricsMonitor: ProcessMetricsMonitor?
    private var fpsRefreshTimer: Timer?
    /// Tracks last output time per terminal for active-output indicator.
    private var lastOutputTimes: [UUID: Date] = [:]
    private var knownTerminalIDs: Set<UUID> = []
    private var outputIdleTimer: Timer?
    private var activeOutputTerminalIDs: Set<UUID> = []
    private var visibleOutputIndicatorSuppressedUntilByTerminalID: [UUID: Date] = [:]
    private var visibleOutputIndicatorResumeTimer: Timer?
    /// Suppresses active-output indicator briefly after resize.
    private var lastResizeTime: Date = .distantPast
    /// Tracks terminals that have been idle at least once (initial output burst is over).
    private var terminalsEverIdle: Set<UUID> = []
    private let clipboardFileStore = ClipboardFileStore()
    private let pastedImageRegistry = PastedImageRegistry.shared
    /// Per-controller ordered list of pasted image URLs for [Image #N] lookup.
    /// Separate from PastedImageRegistry.indexedImages to avoid Kitty purge.
    private var perControllerPastedImages: [UUID: [URL]] = [:]
    private var clipboardCleanupService: ClipboardCleanupService?
    private var mcpServer: MCPServer?
    private let sessionStore = SessionStore()
    private let singleInstanceLock = SingleInstanceLock()
    private let appNoteStore = AppNoteStore()
    private lazy var exportImportManager = PtermExportImportManager(noteStore: appNoteStore)

    private var cpuUsageByPID: [pid_t: Double] = [:]
    private var lastAppMemoryBytes: UInt64 = 0
    private var lastForegroundProcessIDByTerminalID: [UUID: pid_t] = [:]
    private let sessionPersistenceQueue = DispatchQueue(label: SessionPersistence.queueLabel, qos: .utility)
    private var memoryPressureCoordinator: MemoryPressureCoordinator?
    private lazy var sessionPersistenceCoordinator = DebouncedActionCoordinator(
        debounceInterval: SessionPersistence.debounceInterval,
        scheduleQueue: .main
    ) { [weak self] in
        self?.persistSessionAsynchronously()
    }

    /// Metal renderer (shared by all views)
    private var renderer: MetalRenderer!

    /// Terminal manager (manages all terminal sessions)
    private var manager: TerminalManager!

    /// Integrated view (grid of terminal thumbnails)
    private var integratedView: IntegratedView?
    /// Scrollbar overlay for integrated view (native macOS scrollbar)
    private var scrollbarOverlay: ScrollbarOverlayView?

    /// Focused terminal scroll view (wraps TerminalView with native scrollbar)
    private var terminalScrollView: TerminalScrollView?

    /// Focused terminal view (single terminal occupying the window)
    private var terminalView: TerminalView?
    private var searchBarView: SearchBarView?
    private var splitContainerView: SplitTerminalContainerView?
    private var appNoteEditor: MarkdownEditorWindowController?
    private var settingsController: SettingsWindowController?
    private var aboutController: AboutWindowController?

    /// Currently focused terminal controller (nil = integrated view mode)
    private var focusedController: TerminalController?

    /// Controllers saved when maximizing a terminal from split view (for restore)
    private var splitOriginControllers: [TerminalController]?
    /// Root split saved alongside `splitOriginControllers` for focused return flows.
    private var splitOriginAncestorControllers: [TerminalController]?
    /// Controllers saved when the current split itself should return to a previous split.
    private var splitReturnControllers: [TerminalController]?
    private let launchOptions: LaunchOptions
    private static let mcpDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// View mode
    private enum ViewMode {
        case integrated
        case focused(TerminalController)
        case split([TerminalController])
    }

    private struct InitialFontConfiguration {
        let name: String
        let size: CGFloat
    }

    private enum WorkspaceNaming {
        static let uncategorized = "Uncategorized"
        static let initialWorkspaceBaseName = "Workspace"
        static let transientBaseName = "Temporary"
    }

    struct PersistedPresentationPlan: Equatable {
        let mode: PersistedSessionState.PresentedMode
        let focusedTerminalID: UUID?
        let splitTerminalIDs: [UUID]
    }

    enum TerminalListPresentation: Equatable {
        case integrated
        case focused(UUID)
        case split([UUID])
    }

    enum InitialLaunchDisposition: Equatable {
        case restoreSession(PersistedSessionState)
        case showIntegrated
        case createInitialTerminalAndShowIntegrated
    }

    static func shouldUseTranslucentWindowMaterial(
        isIntegratedViewVisible: Bool,
        terminalBackgroundOpacity: Double
    ) -> Bool {
        isIntegratedViewVisible || terminalBackgroundOpacity < 0.999
    }

    init(launchOptions: LaunchOptions = LaunchOptions(profileRoot: nil, restoreSessionMode: .attempt, cliMode: false, immediateAction: nil, directLaunch: nil)) {
        self.launchOptions = launchOptions
        super.init()
    }

    static func reconcilePresentationAfterTerminalListChange(
        currentPresentation: TerminalListPresentation,
        remainingTerminalIDs: [UUID]
    ) -> TerminalListPresentation {
        let remainingSet = Set(remainingTerminalIDs)
        switch currentPresentation {
        case .integrated:
            return .integrated
        case .focused(let id):
            return remainingSet.contains(id) ? .focused(id) : .integrated
        case .split(let ids):
            let remaining = ids.filter { remainingSet.contains($0) }
            if remaining.count >= 2 {
                return .split(remaining)
            }
            if let first = remaining.first {
                return .focused(first)
            }
            return .integrated
        }
    }

    static func groupedControllersForSplit(
        _ controllers: [TerminalController],
        displayOrder: [TerminalController]
    ) -> [TerminalController] {
        let displayOrderIndexByID = Dictionary(
            uniqueKeysWithValues: displayOrder.enumerated().map { ($0.element.id, $0.offset) }
        )
        return controllers.sorted { lhs, rhs in
            let lhsWorkspace = splitOrderingKey(lhs.sessionSnapshot.workspaceName)
            let rhsWorkspace = splitOrderingKey(rhs.sessionSnapshot.workspaceName)
            if lhsWorkspace != rhsWorkspace {
                return lhsWorkspace < rhsWorkspace
            }

            let lhsDisplayIndex = displayOrderIndexByID[lhs.id] ?? Int.max
            let rhsDisplayIndex = displayOrderIndexByID[rhs.id] ?? Int.max
            if lhsDisplayIndex != rhsDisplayIndex {
                return lhsDisplayIndex < rhsDisplayIndex
            }

            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func filteredLiveControllers(_ controllers: [TerminalController]?) -> [TerminalController]? {
        guard let controllers else { return nil }
        let liveControllersByID = Dictionary(uniqueKeysWithValues: manager.terminals.map { ($0.id, $0) })
        let filtered = controllers.compactMap { liveControllersByID[$0.id] }
        return filtered.isEmpty ? nil : filtered
    }

    private func controllersAppendingIfNeeded(
        _ controller: TerminalController,
        to controllers: [TerminalController]?
    ) -> [TerminalController]? {
        guard var controllers else { return nil }
        if controllers.contains(where: { $0.id == controller.id }) == false {
            controllers.append(controller)
        }
        return controllers
    }

    private static func splitOrderingKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func statusBarMetrics(
        appMemoryBytes: UInt64,
        cpuUsageByPID: [pid_t: Double]
    ) -> (cpuPercent: Double, memoryBytes: UInt64) {
        (cpuUsageByPID[getpid()] ?? 0, appMemoryBytes)
    }

    static func monitoredMetricsPIDs(
        appPID: pid_t,
        terminals: [TerminalController],
        presentation: TerminalListPresentation,
        appIsActive: Bool,
        windowIsVisible: Bool
    ) -> [pid_t] {
        var pids: [pid_t] = [appPID]
        guard appIsActive, windowIsVisible, case .integrated = presentation else {
            return pids
        }

        for terminal in terminals {
            pids.append(terminal.processID)
            if let foregroundPID = terminal.foregroundProcessID,
               foregroundPID != terminal.processID {
                pids.append(foregroundPID)
            }
        }
        return pids
    }

    static func metricsMonitorInterval(
        presentation: TerminalListPresentation,
        appIsActive: Bool,
        windowIsVisible: Bool
    ) -> TimeInterval {
        guard appIsActive, windowIsVisible else { return 10.0 }
        if case .integrated = presentation {
            return 3.0
        }
        return 10.0
    }

    static func shouldRunMetricsMonitor(
        appIsActive: Bool,
        windowIsVisible: Bool
    ) -> Bool {
        _ = appIsActive
        return windowIsVisible
    }

    static func shouldTrackIntegratedOverviewActivity(
        presentation: TerminalListPresentation,
        appIsActive: Bool,
        windowIsVisible: Bool
    ) -> Bool {
        _ = appIsActive
        guard windowIsVisible else { return false }
        if case .integrated = presentation {
            return true
        }
        return false
    }

    static func shouldReinsertSubview(
        _ subview: NSView,
        below sibling: NSView,
        in parent: NSView
    ) -> Bool {
        guard subview.superview === parent else { return true }
        guard let subviewIndex = parent.subviews.firstIndex(of: subview),
              let siblingIndex = parent.subviews.firstIndex(of: sibling) else {
            return true
        }
        return subviewIndex >= siblingIndex
    }

    static func shouldPromoteOutputActivityToVisibleIndicator(
        terminalHasEverBeenIdle: Bool,
        secondsSinceLastResize: TimeInterval
    ) -> Bool {
        guard terminalHasEverBeenIdle else { return false }
        return secondsSinceLastResize >= 1.0
    }

    @discardableResult
    static func refreshCurrentDirectories(
        for controllers: [TerminalController],
        refresh: ((TerminalController) -> Bool)? = nil
    ) -> Int {
        var refreshed = 0
        var seen: Set<UUID> = []
        for controller in controllers where seen.insert(controller.id).inserted {
            let didRefresh = refresh?(controller) ?? controller.refreshCurrentDirectoryFromShellProcess()
            if didRefresh {
                refreshed += 1
            }
        }
        return refreshed
    }

    static func initialLaunchDisposition(
        restoredSession: PersistedSessionState?,
        bootstrappedConfiguredWorkspaces: Bool
    ) -> InitialLaunchDisposition {
        if let restoredSession {
            return .restoreSession(restoredSession)
        }
        if bootstrappedConfiguredWorkspaces {
            return .showIntegrated
        }
        return .createInitialTerminalAndShowIntegrated
    }

    static func newTerminalShortcutContext(
        focusedController: TerminalController?,
        splitControllers: [TerminalController]
    ) -> (workspaceName: String, displayedControllers: [TerminalController])? {
        if let focusedController {
            return (focusedController.sessionSnapshot.workspaceName, [focusedController])
        }
        guard let lastDisplayedController = splitControllers.last else {
            return nil
        }
        return (lastDisplayedController.sessionSnapshot.workspaceName, splitControllers)
    }

    static func initialWorkspaceName(existingNames: [String]) -> String {
        let normalizedExistingNames = Set(
            existingNames.map {
                FileNameSanitizer.sanitize($0, fallback: WorkspaceNaming.uncategorized)
            }
        )
        let baseName = WorkspaceNaming.initialWorkspaceBaseName
        if !normalizedExistingNames.contains(baseName) {
            return baseName
        }

        var suffix = 2
        while true {
            let candidate = "\(baseName) \(suffix)"
            if !normalizedExistingNames.contains(candidate) {
                return candidate
            }
            suffix += 1
        }
    }

    static func transientWorkspaceName(commandPath: String, id: UUID) -> String {
        let commandName = URL(fileURLWithPath: commandPath).lastPathComponent
        let trimmedCommand = commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(id.uuidString.prefix(8))
        let baseName = trimmedCommand.isEmpty
            ? WorkspaceNaming.transientBaseName
            : "\(WorkspaceNaming.transientBaseName) \(trimmedCommand)"
        return FileNameSanitizer.sanitize("\(baseName) \(suffix)", fallback: WorkspaceNaming.transientBaseName)
    }

    static func persistedPresentationPlan(
        currentPresentation: TerminalListPresentation,
        persistedTerminalIDs: Set<UUID>
    ) -> PersistedPresentationPlan {
        switch currentPresentation {
        case .integrated:
            return PersistedPresentationPlan(mode: .integrated, focusedTerminalID: nil, splitTerminalIDs: [])
        case .focused(let id):
            guard persistedTerminalIDs.contains(id) else {
                return PersistedPresentationPlan(mode: .integrated, focusedTerminalID: nil, splitTerminalIDs: [])
            }
            return PersistedPresentationPlan(mode: .focused, focusedTerminalID: id, splitTerminalIDs: [])
        case .split(let ids):
            let remaining = ids.filter { persistedTerminalIDs.contains($0) }
            if remaining.count >= 2 {
                return PersistedPresentationPlan(mode: .split, focusedTerminalID: nil, splitTerminalIDs: remaining)
            }
            if let first = remaining.first {
                return PersistedPresentationPlan(mode: .focused, focusedTerminalID: first, splitTerminalIDs: [])
            }
            return PersistedPresentationPlan(mode: .integrated, focusedTerminalID: nil, splitTerminalIDs: [])
        }
    }

    private var viewMode: ViewMode = .integrated
    private var isTerminating = false
    private var isRestoringSession = false
    private var isWindowLayoutReady = false
    private var workspaceNames: [String] = []
    private lazy var isNoteEditorSelfTestEnabled: Bool = {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        return arguments.contains("--note-editor-selftest") ||
            environment["PTERM_NOTE_EDITOR_SELFTEST"] == "1"
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !isNoteEditorSelfTestEnabled {
            do {
                if try !singleInstanceLock.acquireOrActivateExisting() {
                    NSApp.terminate(nil)
                    return
                }
            } catch {
                fatalError("Failed to acquire single-instance lock: \(error)")
            }
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(activateFromSecondaryInstance(_:)),
            name: SingleInstanceLock.activationNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidHide(_:)),
            name: NSApplication.didHideNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidUnhide(_:)),
            name: NSApplication.didUnhideNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Ensure ~/.pterm/ directories exist
        PtermDirectories.ensureDirectories()
        config = PtermConfigStore.load()
        lastLoadedConfigSignature = ConfigFileSignature.capture(at: PtermDirectories.config)
        TypewriterSoundPlayer.shared.configure(enabled: config.textInteraction.typewriterSoundEnabled)
        startConfigWatcher()

        // Initialize Metal renderer
        guard let renderer = MetalRenderer(
            scaleFactor: NSScreen.main?.backingScaleFactor ?? 2.0
        ) else {
            fatalError("Failed to initialize Metal. GPU rendering is required.")
        }
        self.renderer = renderer
        renderer.updateTerminalAppearance(config.terminalAppearance)
        memoryPressureCoordinator = MemoryPressureCoordinator { [weak self] in
            self?.handleMemoryPressure()
        }

        // Load Metal shaders
        loadShaders()

        // Create window
        let appWindow = PtermWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        appWindow.onBackToIntegratedShortcut = { [weak self] in
            guard let self else { return }
            switch self.viewMode {
            case .focused, .split:
                self.switchToIntegrated()
            case .integrated:
                break
            }
        }
        appWindow.onInterruptShortcut = { [weak self] in
            self?.handleHighPriorityInterruptShortcut() ?? false
        }
        appWindow.onCommandModifierChange = { [weak self] isHeld in
            guard let self else { return }
            if !isHeld {
                self.commandIdentityHeaderSuppressedUntilCommandRelease = false
            }
            self.setCommandIdentityHeadersVisible(self.currentCommandIdentityHeadersVisible())
        }
        window = appWindow
        window.center()
        window.title = "pterm"
        window.minSize = NSSize(width: 400, height: 300)
        window.delegate = self
        window.isRestorable = false // Disable macOS state restoration
        setupWindowContentHierarchy()
        installTitlebarBackButton()

        configureWindowAppearance()

        let directLaunchOnlyStartup = launchOptions.directLaunch != nil
        let restoredSession = directLaunchOnlyStartup ? nil : loadRestorableSession()
        applyInitialFontConfiguration(restoredSession)
        if let restoredSession {
            window.setFrame(restoredSession.windowFrame.rect, display: false)
        }

        statusBarView = StatusBarView(frame: statusBarFrame())
        statusBarView.autoresizingMask = [.width, .maxYMargin]
        statusBarView.onBackToIntegrated = { [weak self] in
            self?.backToIntegratedView(nil)
        }
        statusBarView.onOpenNote = { [weak self] in
            self?.editAppNote()
        }
        statusBarView.setFPSVisible(config.textInteraction.showFPSInStatusBar)
        contentHostView().addSubview(statusBarView)
        updateFPSRefreshTimer()

        // Create terminal manager with initial grid size
        let pad = renderer.gridPadding * 2
        let contentBounds = availableContentFrame()
        let cols = max(1, Int((contentBounds.width - pad) / renderer.glyphAtlas.cellWidth))
        let rows = max(1, Int((contentBounds.height - pad) / renderer.glyphAtlas.cellHeight))
        manager = TerminalManager(rows: rows, cols: cols, config: config)
        isWindowLayoutReady = true
        synchronizeWindowLayout(shouldPersistSession: false)

        // React to terminal list changes
        manager.onListChanged = { [weak self] in
            self?.handleTerminalListChanged()
        }

        if directLaunchOnlyStartup {
            performDirectLaunchIfRequested()
        } else {
            let bootstrappedConfiguredWorkspaces: Bool
            if restoredSession == nil {
                bootstrappedConfiguredWorkspaces = bootstrapConfiguredWorkspaces()
            } else {
                bootstrappedConfiguredWorkspaces = false
            }
            switch Self.initialLaunchDisposition(
                restoredSession: restoredSession,
                bootstrappedConfiguredWorkspaces: bootstrappedConfiguredWorkspaces
            ) {
            case .restoreSession(let restoredSession):
                restoreSession(restoredSession)
            case .showIntegrated:
                switchToIntegrated()
            case .createInitialTerminalAndShowIntegrated:
                _ = addInitialWorkspaceTerminal()
                switchToIntegrated()
            }
        }

        // Show window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if case .integrated = viewMode {
            window.makeFirstResponder(integratedView)
        }
        runNoteEditorSelfTestIfRequested()
        startMetricsMonitor()
        let cleanupService = ClipboardCleanupService(fileStore: clipboardFileStore)
        cleanupService.start()
        clipboardCleanupService = cleanupService
        installBackShortcutMonitor()
        installCommandIdentityModifierMonitor()
        installCommandIdentityShortcutMonitor()

        // Setup menu
        setupMenu()
        configureMCPServer()
    }

    private func performDirectLaunchIfRequested() {
        guard let directLaunch = launchOptions.directLaunch else { return }
        let terminalID = UUID()
        let workspaceName = Self.transientWorkspaceName(
            commandPath: directLaunch.executablePath,
            id: terminalID
        )
        guard let controller = addNewTerminal(
            executablePath: directLaunch.executablePath,
            executableArguments: directLaunch.arguments,
            isTransient: true,
            workspaceName: workspaceName,
            id: terminalID,
            startAsynchronously: true
        ) else {
            return
        }
        switchToFocused(controller)
    }

    private func runNoteEditorSelfTestIfRequested() {
        guard isNoteEditorSelfTestEnabled else {
            return
        }
        let diagnosticsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pterm-note-editor-selftest", isDirectory: true)
        try? FileManager.default.createDirectory(at: diagnosticsRoot, withIntermediateDirectories: true)
        let logURL = diagnosticsRoot.appendingPathComponent("selftest.log")
        try? "start\n".write(to: logURL, atomically: true, encoding: .utf8)

        let controller = MarkdownEditorWindowController(
            initialText: "abc\n日本語\n- item",
            onSave: { _ in }
        )
        controller.showEditorWindow()
        try? "window-shown\n".appendLine(to: logURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            try? "selftest-done\n".appendLine(to: logURL)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !isTerminating {
            let aliveCount = manager.terminals.filter { $0.isAlive }.count
            if aliveCount > 0 {
                let alert = NSAlert.pterm()
                alert.messageText = "Quit pterm?"
                alert.informativeText = "\(aliveCount) terminal(s) are still running."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Cancel")

                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    return .terminateCancel
                }
            }
        }

        if !isTerminating {
            isTerminating = true
            flushPendingSessionPersistence()
        }
        clipboardCleanupService?.stop()
        manager.stopAll(
            preserveScrollback: config.sessionScrollBufferPersistence,
            waitForExit: true
        )
        try? sessionStore.markCleanShutdown()
        singleInstanceLock.release()
        removeCommandIdentityModifierMonitor()
        removeCommandIdentityShortcutMonitor()
        return .terminateNow
    }

    // MARK: - Terminal Management

    @discardableResult
    private func addNewTerminal(initialDirectory: String? = nil,
                                executablePath: String? = nil,
                                executableArguments: [String] = [],
                                isTransient: Bool = false,
                                customTitle: String? = nil,
                                workspaceName: String = "Uncategorized",
                                textEncoding: TerminalTextEncoding? = nil,
                                fontName: String? = nil,
                                fontSize: Double? = nil,
                                id: UUID = UUID(),
                                startAsynchronously: Bool = false) -> TerminalController? {
        if !isTransient {
            ensureWorkspaceExists(named: workspaceName)
        }
        do {
            let controller = try manager.addTerminal(
                initialDirectory: initialDirectory,
                executablePath: executablePath,
                executableArguments: executableArguments,
                isTransient: isTransient,
                customTitle: customTitle,
                workspaceName: normalizedWorkspaceName(workspaceName),
                textEncoding: textEncoding,
                fontName: fontName ?? renderer.glyphAtlas.fontName,
                fontSize: fontSize ?? Double(renderer.glyphAtlas.fontSize),
                id: id,
                startAsynchronously: startAsynchronously,
                onStartFailure: { error in
                    let alert = NSAlert.pterm()
                    alert.messageText = "Failed to start terminal"
                    alert.informativeText = "\(error)"
                    alert.alertStyle = .critical
                    alert.runModal()
                },
                configure: { [weak self] controller in
                    self?.configureController(controller)
                }
            )
            return controller
        } catch {
            let alert = NSAlert.pterm()
            alert.messageText = "Failed to start terminal"
            alert.informativeText = "\(error)"
            alert.alertStyle = .critical
            alert.runModal()
            return nil
        }
    }

    private func handleTerminalListChanged() {
        if isTerminating {
            return
        }

        let remainingTerminalIDs = Set(manager.terminals.map(\.id))
        let removedTerminalIDs = knownTerminalIDs.subtracting(remainingTerminalIDs)
        for removedID in removedTerminalIDs {
            purgeInlineImageResources(ownerID: removedID, retaining: [], removingOwner: true)
        }
        knownTerminalIDs = remainingTerminalIDs
        lastOutputTimes = lastOutputTimes.filter { remainingTerminalIDs.contains($0.key) }
        terminalsEverIdle = terminalsEverIdle.intersection(remainingTerminalIDs)
        activeOutputTerminalIDs = activeOutputTerminalIDs.intersection(remainingTerminalIDs)
        visibleOutputIndicatorSuppressedUntilByTerminalID =
            visibleOutputIndicatorSuppressedUntilByTerminalID.filter { remainingTerminalIDs.contains($0.key) }
        scheduleVisibleOutputIndicatorResumeIfNeeded()
        syncVisibleTerminalOutputIndicators()

        splitOriginControllers = filteredLiveControllers(splitOriginControllers)
        splitOriginAncestorControllers = filteredLiveControllers(splitOriginAncestorControllers)
        splitReturnControllers = filteredLiveControllers(splitReturnControllers)

        let wasIntegrated = {
            if case .integrated = viewMode { return true }
            return false
        }()

        switch viewMode {
        case .integrated:
            break
        case .focused(let controller):
            if let liveFocusedController = manager.terminals.first(where: { $0.id == controller.id }) {
                switchToFocused(liveFocusedController)
            } else if let originControllers = splitOriginControllers {
                if originControllers.count >= 2 {
                    switchToSplit(originControllers, returnToControllers: splitOriginAncestorControllers)
                } else if let first = originControllers.first {
                    let ancestorControllers = splitOriginAncestorControllers
                    splitOriginControllers = ancestorControllers ?? originControllers
                    splitOriginAncestorControllers = ancestorControllers
                    switchToFocused(first)
                } else {
                    switchToIntegrated()
                }
            } else if let ancestorControllers = splitOriginAncestorControllers {
                if ancestorControllers.count >= 2 {
                    switchToSplit(ancestorControllers)
                } else if let first = ancestorControllers.first {
                    splitOriginControllers = nil
                    splitOriginAncestorControllers = nil
                    switchToFocused(first)
                } else {
                    switchToIntegrated()
                }
            } else {
                switchToIntegrated()
            }
        case .split(let controllers):
            let liveControllersByID = Dictionary(uniqueKeysWithValues: manager.terminals.map { ($0.id, $0) })
            let currentSplitControllers = controllers.compactMap { liveControllersByID[$0.id] }
            let ancestorSplitControllers = splitReturnControllers

            if currentSplitControllers.count >= 2 {
                switchToSplit(currentSplitControllers, returnToControllers: ancestorSplitControllers)
            } else if currentSplitControllers.count == 1, let first = currentSplitControllers.first {
                splitOriginControllers = ancestorSplitControllers ?? currentSplitControllers
                splitOriginAncestorControllers = ancestorSplitControllers
                switchToFocused(first)
            } else if let ancestorSplitControllers {
                if ancestorSplitControllers.count >= 2 {
                    switchToSplit(ancestorSplitControllers)
                } else if let first = ancestorSplitControllers.first {
                    splitOriginControllers = nil
                    splitOriginAncestorControllers = nil
                    switchToFocused(first)
                } else {
                    switchToIntegrated()
                }
            } else {
                switchToIntegrated()
            }
        }

        if wasIntegrated, case .integrated = viewMode {
            integratedView?.terminalListDidChange()
        }

        if manager.terminals.isEmpty {
            renderer.glyphAtlas.resetToMinimum()
            applyAppearanceSettingsToVisibleViews()
        }

        updateWindowTitle()
        requestSessionPersist()
    }

    private func purgeInlineImageResources(ownerID: UUID, retaining liveIndices: Set<Int>, removingOwner: Bool = false) {
        let evictedURLs = pastedImageRegistry.purgeUnreferencedImages(
            ownerID: ownerID,
            retainingPlaceholderIndices: liveIndices
        )
        TerminalInlineImageSupport.evictCachedImages(for: evictedURLs)
        renderer.releaseInlineImageTextures(ownerID: ownerID, retaining: liveIndices)
        terminalView?.pruneInlineImageResources(ownerID: ownerID, retaining: liveIndices)
        splitContainerView?.pruneInlineImageResources(ownerID: ownerID, retaining: liveIndices)
        if removingOwner {
            pastedImageRegistry.removeImages(ownerID: ownerID)
            renderer.releaseInlineImageTextures(ownerID: ownerID)
            terminalView?.pruneInlineImageResources(ownerID: ownerID, retaining: [])
            splitContainerView?.pruneInlineImageResources(ownerID: ownerID, retaining: [])
        }
    }

    // MARK: - View Switching

    private func switchToFocused(_ controller: TerminalController) {
        Self.refreshCurrentDirectories(for: [controller])
        applyRendererSettings(for: controller)

        splitContainerView?.detachControllersForPresentationTransition()
        terminalView?.detachControllerForPresentationTransition()

        // Create focused terminal view wrapped in scroll view
        let sv = TerminalScrollView(frame: presentationHostView().bounds, renderer: renderer)
        sv.autoresizingMask = [.width, .height]
        sv.shortcutConfiguration = config.shortcuts
        sv.terminalView.outputConfirmedInputAnimationsEnabled = config.textInteraction.outputConfirmedInputAnimation
        sv.terminalView.outputFrameThrottlingMode = config.textInteraction.outputFrameThrottlingMode
        sv.terminalView.typewriterSoundEnabled = config.textInteraction.typewriterSoundEnabled
        sv.terminalView.imagePreviewURLProvider = { [weak self] ownerID, index in
            self?.pastedImageRegistry.url(ownerID: ownerID, forPlaceholderIndex: index)
        }
        sv.terminalView.textImagePlaceholderURLProvider = { [weak self] ownerID, index in
            guard let self, index > 0 else { return nil }
            guard let list = self.perControllerPastedImages[ownerID], index <= list.count else { return nil }
            let url = list[index - 1]
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        sv.terminalView.onFileDropURLs = { [weak self] controller, urls in
            guard let self else { return false }
            return self.handleTerminalFileDrop(controller: controller, urls: urls)
        }
        sv.terminalView.onBackToIntegrated = { [weak self] in
            self?.switchToIntegrated()
        }
        sv.terminalView.onCmdClick = { [weak self] in
            guard let self, let controllers = self.splitOriginControllers else { return }
            self.splitOriginControllers = nil
            let ancestorControllers = self.splitOriginAncestorControllers
            self.splitOriginAncestorControllers = nil
            self.switchToSplit(controllers, returnToControllers: ancestorControllers)
        }
        if splitOriginControllers != nil {
            sv.terminalView.cmdClickTooltip = "⌘+Click to return to split view"
        }
        presentationHostView().addSubview(sv)

        terminalView?.scrubPresentedDrawableForRemoval()
        terminalView?.releaseInactiveRenderingResourcesNow()
        terminalScrollView?.removeFromSuperview()
        terminalScrollView = nil
        terminalView = nil
        focusedController = nil
        hideSearchBar()

        integratedView?.releaseInactiveRenderingResourcesNow()
        integratedView?.removeFromSuperview()
        integratedView = nil
        scrollbarOverlay?.removeFromSuperview()
        scrollbarOverlay = nil
        splitContainerView?.scrubPresentedDrawableForRemoval()
        splitContainerView?.releaseInactiveRenderingResourcesNow()
        splitContainerView?.removeFromSuperview()
        splitContainerView = nil

        terminalScrollView = sv
        terminalView = sv.terminalView
        sv.terminalView.terminalController = controller
        suppressVisibleOutputIndicators(for: [controller.id])
        terminalView?.applyAppearanceSettings()
        focusedController = controller
        splitReturnControllers = nil

        viewMode = .focused(controller)
        applyAppearanceSettingsToVisibleViews()
        updateTitlebarBackButtonVisibility()
        refreshMetricsMonitoringState()
        refreshStatusBarMetrics()
        refreshStatusBarCommandHints()
        setCommandIdentityHeadersVisible(currentCommandModifierHeld())
        window.makeFirstResponder(sv.terminalView)
        sv.terminalView.syncScaleFactorIfNeeded()

        updateWindowTitle()
        requestSessionPersist()
    }

    func switchToSplit(_ controllers: [TerminalController]) {
        switchToSplit(controllers, returnToControllers: nil)
    }

    private func switchToSplit(_ controllers: [TerminalController], returnToControllers: [TerminalController]?) {
        let orderedControllers = Self.groupedControllersForSplit(controllers, displayOrder: manager.terminals)
        let orderedReturnControllers = returnToControllers.map { Self.groupedControllersForSplit($0, displayOrder: manager.terminals) }
        guard orderedControllers.count >= 2 else {
            if let first = orderedControllers.first {
                splitOriginControllers = orderedReturnControllers ?? orderedControllers
                splitOriginAncestorControllers = orderedReturnControllers
                switchToFocused(first)
            } else {
                switchToIntegrated()
            }
            return
        }

        Self.refreshCurrentDirectories(for: orderedControllers)

        terminalView?.detachControllerForPresentationTransition()
        splitContainerView?.detachControllersForPresentationTransition()

        let splitView = SplitTerminalContainerView(frame: presentationHostView().bounds,
                                                   renderer: renderer,
                                                   controllers: orderedControllers)
        splitView.autoresizingMask = [.width, .height]
        splitView.shortcutConfiguration = config.shortcuts
        splitView.outputConfirmedInputAnimationsEnabled = config.textInteraction.outputConfirmedInputAnimation
        splitView.outputFrameThrottlingMode = config.textInteraction.outputFrameThrottlingMode
        splitView.typewriterSoundEnabled = config.textInteraction.typewriterSoundEnabled
        splitView.imagePreviewURLProvider = { [weak self] ownerID, index in
            self?.pastedImageRegistry.url(ownerID: ownerID, forPlaceholderIndex: index)
        }
        splitView.textImagePlaceholderURLProvider = { [weak self] ownerID, index in
            guard let self, index > 0 else { return nil }
            guard let list = self.perControllerPastedImages[ownerID], index <= list.count else { return nil }
            let url = list[index - 1]
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        splitView.onFileDropURLs = { [weak self] controller, urls in
            guard let self else { return false }
            return self.handleTerminalFileDrop(controller: controller, urls: urls)
        }
        splitView.onActiveControllerChange = { [weak self] controller in
            self?.applyRendererSettings(for: controller)
        }
        splitView.onBackToIntegrated = { [weak self] in
            self?.switchToIntegrated()
        }
        splitView.commandClickTooltip =
            orderedReturnControllers == nil
            ? "⌘+Click to maximize this terminal"
            : "⌘+Click to return to previous split view"
        splitView.onMaximizeTerminal = { [weak self] controller in
            guard let self else { return }
            self.splitOriginControllers = orderedControllers
            self.splitOriginAncestorControllers = orderedReturnControllers
            self.switchToFocused(controller)
        }
        splitView.onCommandClickTerminal = { [weak self] controller in
            guard let self else { return }
            if let returnControllers = orderedReturnControllers {
                self.switchToSplit(returnControllers)
            } else {
                self.splitOriginControllers = orderedControllers
                self.splitOriginAncestorControllers = nil
                self.switchToFocused(controller)
            }
        }
        splitView.onCommitSelectedControllers = { [weak self] selectedControllers in
            guard let self else { return }
            let orderedSelection = Self.groupedControllersForSplit(selectedControllers, displayOrder: self.manager.terminals)
            guard !orderedSelection.isEmpty else { return }
            let ancestorSplitControllers = orderedReturnControllers ?? orderedControllers
            if orderedSelection.count == 1, let controller = orderedSelection.first {
                self.splitOriginControllers = orderedControllers
                self.splitOriginAncestorControllers = orderedReturnControllers
                self.switchToFocused(controller)
            } else {
                self.switchToSplit(orderedSelection, returnToControllers: ancestorSplitControllers)
            }
        }
        presentationHostView().addSubview(splitView)

        integratedView?.releaseInactiveRenderingResourcesNow()
        integratedView?.removeFromSuperview()
        integratedView = nil
        scrollbarOverlay?.removeFromSuperview()
        scrollbarOverlay = nil
        splitContainerView?.scrubPresentedDrawableForRemoval()
        splitContainerView?.releaseInactiveRenderingResourcesNow()
        splitContainerView?.removeFromSuperview()
        splitContainerView = nil
        terminalView?.scrubPresentedDrawableForRemoval()
        terminalView?.releaseInactiveRenderingResourcesNow()
        terminalScrollView?.removeFromSuperview()
        terminalScrollView = nil
        terminalView = nil
        focusedController = nil
        hideSearchBar()

        splitContainerView = splitView
        presentationHostView().layoutSubtreeIfNeeded()
        splitView.layoutSubtreeIfNeeded()
        splitView.syncScaleFactorIfNeeded()
        suppressVisibleOutputIndicators(for: orderedControllers.map(\.id))
        splitContainerView?.applyAppearanceSettings()
        splitReturnControllers = orderedReturnControllers
        splitOriginControllers = nil
        splitOriginAncestorControllers = nil
        viewMode = .split(orderedControllers)
        applyAppearanceSettingsToVisibleViews()
        updateTitlebarBackButtonVisibility()
        refreshMetricsMonitoringState()
        refreshStatusBarMetrics()
        refreshStatusBarCommandHints()
        setCommandIdentityHeadersVisible(currentCommandModifierHeld())
        if let activeController = splitView.activeController {
            applyRendererSettings(for: activeController)
        }
        if let first = splitView.subviews.first as? TerminalScrollView {
            window.makeFirstResponder(first.terminalView)
        }
        updateWindowTitle()
        requestSessionPersist()
    }

    private func switchToIntegrated() {
        Self.refreshCurrentDirectories(for: manager.terminals)

        terminalView?.detachControllerForPresentationTransition()
        splitContainerView?.detachControllersForPresentationTransition()

        // Show integrated view
        let iv: IntegratedView
        if let existing = integratedView {
            iv = existing
        } else {
            iv = makeIntegratedView(frame: presentationHostView().bounds)
            integratedView = iv
        }

        iv.frame = presentationHostView().bounds
        iv.clearSelection()
        syncIntegratedWorkspaceNames()
        presentationHostView().addSubview(iv)
        setupScrollbarOverlay(for: iv)
        iv.invalidateDynamicThumbnailCaches()
        activeOutputTerminalIDs.forEach { _ = iv.setTerminalOutputActive($0, isActive: true) }

        terminalView?.scrubPresentedDrawableForRemoval()
        terminalView?.releaseInactiveRenderingResourcesNow()
        terminalScrollView?.removeFromSuperview()
        terminalScrollView = nil
        splitContainerView?.scrubPresentedDrawableForRemoval()
        splitContainerView?.releaseInactiveRenderingResourcesNow()
        splitContainerView?.removeFromSuperview()
        splitContainerView = nil
        terminalView = nil
        focusedController = nil
        splitOriginControllers = nil
        splitOriginAncestorControllers = nil
        splitReturnControllers = nil
        hideSearchBar()

        viewMode = .integrated
        applyAppearanceSettingsToVisibleViews()
        iv.syncScaleFactorIfNeeded()
        updateTitlebarBackButtonVisibility()
        refreshMetricsMonitoringState()
        refreshStatusBarMetrics()
        refreshStatusBarCommandHints()
        setCommandIdentityHeadersVisible(false)
        window.makeFirstResponder(iv)

        updateWindowTitle()
        requestSessionPersist()
    }

    private func makeIntegratedView(frame: NSRect) -> IntegratedView {
        let iv = IntegratedView(frame: frame, renderer: renderer, manager: manager)
        iv.autoresizingMask = [.width, .height]
        iv.shortcutConfiguration = config.shortcuts
        iv.outputFrameThrottlingMode = config.textInteraction.outputFrameThrottlingMode
        iv.onSelectTerminal = { [weak self] controller in
            self?.switchToFocused(controller)
        }
        iv.onAddWorkspace = { [weak self] in
            self?.promptCreateWorkspace()
        }
        iv.onAddTerminalToWorkspace = { [weak self] workspace in
            self?.addNewTerminal(workspaceName: workspace, startAsynchronously: true)
        }
        iv.onRemoveWorkspace = { [weak self] workspace in
            self?.confirmAndRemoveWorkspace(named: workspace)
        }
        iv.onRemoveTerminal = { [weak self] controller in
            self?.confirmAndRemoveTerminal(controller)
        }
        iv.onRenameWorkspace = { [weak self] oldName, newName in
            self?.renameWorkspace(from: oldName, to: newName)
        }
        iv.onMoveTerminalToWorkspace = { [weak self] controller, workspace in
            self?.moveTerminal(controller, toWorkspace: workspace)
        }
        iv.onRenameTerminalTitle = { [weak self] controller, title in
            self?.renameTerminalTitle(controller, title: title)
        }
        iv.onMultiSelect = { [weak self] controllers in
            self?.switchToSplit(controllers)
        }
        iv.onReorderTerminal = { [weak self] controller, workspace, index in
            self?.reorderTerminal(controller, toWorkspace: workspace, atIndex: index)
        }
        iv.onReorderWorkspace = { [weak self] name, index in
            self?.reorderWorkspace(name, toIndex: index)
        }
        iv.cpuUsageProvider = { [weak self] pid in
            self?.cpuUsageByPID[pid]
        }
        return iv
    }

    private func applyRendererSettings(for controller: TerminalController) {
        let settings = controller.persistedFontSettings
        let targetFontName = settings.name
        let targetFontSize = CGFloat(settings.size)
        guard renderer.glyphAtlas.fontName != targetFontName ||
                abs(renderer.glyphAtlas.fontSize - targetFontSize) > 0.001 else {
            applyAppearanceSettingsToVisibleViews()
            return
        }

        renderer.updateFont(name: targetFontName, size: targetFontSize)
        terminalView?.fontSizeDidChange()
        splitContainerView?.fontSizeDidChange()
        integratedView?.setNeedsDisplay(integratedView?.bounds ?? .zero)
        applyAppearanceSettingsToVisibleViews()
        updateWindowTitle()
    }

    private func refreshStatusBarMetrics() {
        let metrics = Self.statusBarMetrics(
            appMemoryBytes: lastAppMemoryBytes,
            cpuUsageByPID: cpuUsageByPID
        )
        statusBarView.updateCpuUsage(percent: metrics.cpuPercent)
        statusBarView.updateMemoryUsage(bytes: metrics.memoryBytes)
        statusBarView.updateFPS(config.textInteraction.showFPSInStatusBar ? RenderFPSMonitor.shared.currentFPS() : nil)
    }

    private func updateFPSRefreshTimer() {
        fpsRefreshTimer?.invalidate()
        fpsRefreshTimer = nil
        guard config.textInteraction.showFPSInStatusBar else {
            statusBarView?.updateFPS(nil)
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.statusBarView?.updateFPS(RenderFPSMonitor.shared.currentFPS())
        }
        RunLoop.main.add(timer, forMode: .common)
        fpsRefreshTimer = timer
    }

    private var currentPresentation: TerminalListPresentation {
        switch viewMode {
        case .integrated:
            return .integrated
        case .focused(let controller):
            return .focused(controller.id)
        case .split(let controllers):
            return .split(controllers.map(\.id))
        }
    }

    private func startMetricsMonitor() {
        metricsMonitor?.stop()
        metricsMonitor = nil
        guard Self.shouldRunMetricsMonitor(
            appIsActive: NSApp.isActive,
            windowIsVisible: window?.occlusionState.contains(.visible) ?? true
        ) else {
            return
        }
        let monitor = ProcessMetricsMonitor(
            interval: Self.metricsMonitorInterval(
                presentation: currentPresentation,
                appIsActive: NSApp.isActive,
                windowIsVisible: window?.occlusionState.contains(.visible) ?? false
            )
        )
        monitor.onUpdate = { [weak self] snapshot in
            guard let self else { return }
            self.cpuUsageByPID = snapshot.cpuUsageByPID
            self.lastAppMemoryBytes = snapshot.appMemoryBytes
            let activeTerminalIDs = Set(self.manager.terminals.map(\.id))
            self.lastForegroundProcessIDByTerminalID =
                self.lastForegroundProcessIDByTerminalID.filter { activeTerminalIDs.contains($0.key) }
            self.manager.terminals.forEach { terminal in
                let foregroundPID = terminal.foregroundProcessID ?? terminal.processID
                let previousForegroundPID = self.lastForegroundProcessIDByTerminalID.updateValue(
                    foregroundPID,
                    forKey: terminal.id
                )
                if previousForegroundPID != foregroundPID {
                    _ = terminal.refreshCurrentDirectoryFromShellProcess()
                }
            }
            self.refreshStatusBarMetrics()
        }
        monitor.start { [weak self] in
            guard let self else { return [] }
            return Self.monitoredMetricsPIDs(
                appPID: getpid(),
                terminals: self.manager.terminals,
                presentation: self.currentPresentation,
                appIsActive: NSApp.isActive,
                windowIsVisible: self.window?.occlusionState.contains(.visible) ?? false
            )
        }
        metricsMonitor = monitor
    }

    private func stopMetricsMonitor() {
        metricsMonitor?.stop()
        metricsMonitor = nil
    }

    private func refreshMetricsMonitoringState() {
        if Self.shouldRunMetricsMonitor(
            appIsActive: NSApp.isActive,
            windowIsVisible: window?.occlusionState.contains(.visible) ?? false
        ) {
            startMetricsMonitor()
        } else {
            stopMetricsMonitor()
        }
    }

    private func availableContentFrame() -> NSRect {
        let bounds = contentHostView().bounds
        let searchInset = searchBarView == nil ? 0 : Layout.searchBarHeight
        return NSRect(
            x: bounds.origin.x,
            y: bounds.origin.y + Layout.statusBarHeight,
            width: bounds.width,
            height: max(0, bounds.height - Layout.statusBarHeight - searchInset)
        )
    }

    private func statusBarFrame() -> NSRect {
        let bounds = contentHostView().bounds
        return NSRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: Layout.statusBarHeight)
    }

    private func searchBarFrame() -> NSRect {
        let bounds = contentHostView().bounds
        return NSRect(x: bounds.origin.x + 12,
                      y: bounds.maxY - Layout.searchBarHeight - 8,
                      width: bounds.width - 24,
                      height: Layout.searchBarHeight)
    }

    // MARK: - Metal Shaders

    private func loadShaders() {
        let bundle = Bundle.main
        if let libraryURL = bundle.url(forResource: "default", withExtension: "metallib"),
           let library = try? renderer.device.makeLibrary(URL: libraryURL) {
            renderer.setupPipelines(library: library)
            return
        }
        fatalError("Missing bundled shader library: default.metallib")
    }

    // MARK: - Menu

    private func setupMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About pterm",
                       action: #selector(showAboutPanel),
                       keyEquivalent: "")
        appMenu.addItem(makeMenuItem(title: "Settings\u{2026}", shortcut: .openSettings))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Export", action: #selector(exportData(_:)),
                        keyEquivalent: "")
        appMenu.addItem(withTitle: "Import", action: #selector(importData(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Open Clipboard Files", action: #selector(openClipboardFilesFolder(_:)),
                        keyEquivalent: "")
        appMenu.addItem(withTitle: "Delete Clipboard Files", action: #selector(clearClipboardFiles(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(makeMenuItem(title: "Quit pterm", shortcut: .quit))
        appMenuItem.submenu = appMenu

        // Edit menu (for standard key bindings)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(makeMenuItem(title: "Copy", shortcut: .copy))
        editMenu.addItem(makeMenuItem(title: "Cut", shortcut: .cut))
        editMenu.addItem(makeMenuItem(title: "Paste", shortcut: .paste))
        editMenu.addItem(makeMenuItem(title: "Select All", shortcut: .selectAll))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(makeMenuItem(title: "Undo", shortcut: .undo))
        editMenu.addItem(makeMenuItem(title: "Find...", shortcut: .find))
        editMenuItem.submenu = editMenu

        // View menu (font size control + view switching)
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")

        viewMenu.addItem(makeMenuItem(title: "Zoom In", shortcut: .zoomIn))
        viewMenu.addItem(makeMenuItem(title: "Zoom Out", shortcut: .zoomOut))
        viewMenu.addItem(makeMenuItem(title: "Reset to Default Size", shortcut: .zoomReset))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(makeMenuItem(title: "Clear Screen", shortcut: .clearScreen))
        viewMenu.addItem(makeMenuItem(title: "Scroll to Top", shortcut: .scrollToTop))

        viewMenu.addItem(NSMenuItem.separator())

        viewMenu.addItem(makeMenuItem(title: "Back to Overview", shortcut: .backToIntegrated))

        viewMenuItem.submenu = viewMenu

        // Shell menu
        let shellMenuItem = NSMenuItem()
        mainMenu.addItem(shellMenuItem)
        let shellMenu = NSMenu(title: "Shell")
        shellMenu.addItem(makeMenuItem(title: "New Terminal", shortcut: .newTerminal))
        shellMenu.addItem(makeMenuItem(title: "Close Terminal", shortcut: .closeTerminal))
        shellMenu.addItem(NSMenuItem.separator())
        shellMenu.addItem(withTitle: "Edit Note", action: #selector(editAppNote(_:)),
                          keyEquivalent: "")
        shellMenuItem.submenu = shellMenu

        NSApplication.shared.mainMenu = mainMenu
    }

    private func startConfigWatcher() {
        stopConfigWatcher()

        let fd = open(PtermDirectories.base.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link, .revoke],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard FileManager.default.fileExists(atPath: PtermDirectories.config.path) else {
                return
            }
            self?.scheduleConfigReload()
        }
        source.setCancelHandler {
            close(fd)
        }

        configWatchSource = source
        source.resume()
    }

    private func installBackShortcutMonitor() {
        removeBackShortcutMonitor()
        backShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.config.shortcuts.matches(.backToIntegrated, event: event) else { return event }
            switch self.viewMode {
            case .focused, .split:
                self.switchToIntegrated()
                return nil
            case .integrated:
                return event
            }
        }
    }

    private func removeBackShortcutMonitor() {
        if let backShortcutMonitor {
            NSEvent.removeMonitor(backShortcutMonitor)
            self.backShortcutMonitor = nil
        }
    }

    private func installCommandIdentityModifierMonitor() {
        removeCommandIdentityModifierMonitor()
        commandIdentityModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            guard let self else { return }
            if !self.currentCommandModifierHeld() {
                self.commandIdentityHeaderSuppressedUntilCommandRelease = false
            }
            self.setCommandIdentityHeadersVisible(self.currentCommandIdentityHeadersVisible())
        }
    }

    private func removeCommandIdentityModifierMonitor() {
        if let commandIdentityModifierMonitor {
            NSEvent.removeMonitor(commandIdentityModifierMonitor)
            self.commandIdentityModifierMonitor = nil
        }
    }

    private func installCommandIdentityShortcutMonitor() {
        removeCommandIdentityShortcutMonitor()
        commandIdentityShortcutLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleCommandIdentityShortcutMonitor(event)
            return event
        }
        commandIdentityShortcutGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleCommandIdentityShortcutMonitor(event)
        }
    }

    private func removeCommandIdentityShortcutMonitor() {
        if let commandIdentityShortcutLocalMonitor {
            NSEvent.removeMonitor(commandIdentityShortcutLocalMonitor)
            self.commandIdentityShortcutLocalMonitor = nil
        }
        if let commandIdentityShortcutGlobalMonitor {
            NSEvent.removeMonitor(commandIdentityShortcutGlobalMonitor)
            self.commandIdentityShortcutGlobalMonitor = nil
        }
    }

    private func handleCommandIdentityShortcutMonitor(_ event: NSEvent) {
        guard event.modifierFlags.contains(.command),
              event.modifierFlags.contains(.shift),
              event.charactersIgnoringModifiers == "4" else {
            return
        }
        commandIdentityHeaderSuppressedUntilCommandRelease = true
        setCommandIdentityHeadersVisible(false)
    }

    private func installTitlebarBackButton() {
        guard let titlebarView = window.standardWindowButton(.closeButton)?.superview else { return }
        let button = NSButton(title: "▦", target: self, action: #selector(backToIntegratedView(_:)))
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        button.contentTintColor = .white
        button.isHidden = true
        titlebarView.addSubview(button)
        titlebarBackButton = button
        layoutTitlebarBackButton()
    }

    private func layoutTitlebarBackButton() {
        guard let titlebarBackButton,
              let zoomButton = window.standardWindowButton(.zoomButton),
              let titlebarView = zoomButton.superview else { return }
        let zoomFrame = titlebarView.convert(zoomButton.frame, to: nil)
        titlebarBackButton.frame = NSRect(x: zoomFrame.maxX + 12, y: zoomFrame.minY - 1, width: 30, height: 24)
    }

    private func updateTitlebarBackButtonVisibility() {
        let shouldShow: Bool
        let shouldShowOverviewSelectAllHint: Bool
        switch viewMode {
        case .focused, .split:
            shouldShow = true
            shouldShowOverviewSelectAllHint = false
        case .integrated:
            shouldShow = false
            shouldShowOverviewSelectAllHint = true
        }
        titlebarBackButton?.isHidden = !shouldShow
        statusBarView?.setBackButtonVisible(shouldShow)
        statusBarView?.setOverviewSelectAllHintVisible(shouldShowOverviewSelectAllHint)
        layoutTitlebarBackButton()
    }

    private func stopConfigWatcher() {
        pendingConfigReload?.cancel()
        pendingConfigReload = nil
        configWatchSource?.cancel()
        configWatchSource = nil
    }

    private func scheduleConfigReload() {
        pendingConfigReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.reloadConfigurationFromDisk()
            }
        }
        pendingConfigReload = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func reloadConfigurationFromDisk(force: Bool = false) {
        let signature = ConfigFileSignature.capture(at: PtermDirectories.config)
        if !force, signature == lastLoadedConfigSignature {
            return
        }
        lastLoadedConfigSignature = signature

        let previousConfig = config
        let loadedConfig = PtermConfigStore.load()
        config = loadedConfig
        TypewriterSoundPlayer.shared.configure(enabled: config.textInteraction.typewriterSoundEnabled)
        configureMCPServer()
        manager.updateConfiguration(config)
        setupMenu()
        terminalView?.shortcutConfiguration = config.shortcuts
        terminalView?.outputConfirmedInputAnimationsEnabled = config.textInteraction.outputConfirmedInputAnimation
        terminalView?.outputFrameThrottlingMode = config.textInteraction.outputFrameThrottlingMode
        terminalView?.typewriterSoundEnabled = config.textInteraction.typewriterSoundEnabled
        splitContainerView?.shortcutConfiguration = config.shortcuts
        splitContainerView?.outputConfirmedInputAnimationsEnabled = config.textInteraction.outputConfirmedInputAnimation
        splitContainerView?.outputFrameThrottlingMode = config.textInteraction.outputFrameThrottlingMode
        splitContainerView?.typewriterSoundEnabled = config.textInteraction.typewriterSoundEnabled
        integratedView?.shortcutConfiguration = config.shortcuts
        integratedView?.outputFrameThrottlingMode = config.textInteraction.outputFrameThrottlingMode
        statusBarView?.setFPSVisible(config.textInteraction.showFPSInStatusBar)
        updateFPSRefreshTimer()
        refreshStatusBarMetrics()

        if config.terminalAppearance != previousConfig.terminalAppearance {
            renderer.updateTerminalAppearance(config.terminalAppearance)
            applyAppearanceSettingsToVisibleViews()
            integratedView?.setNeedsDisplay(integratedView?.bounds ?? .zero)
        }

        let currentFontName = renderer.glyphAtlas.fontName
        let currentFontSize = renderer.glyphAtlas.fontSize
        let fontName = config.fontName ?? currentFontName
        let fontSize = CGFloat(config.fontSize ?? Double(currentFontSize))
        if fontName != currentFontName || fontSize != currentFontSize {
            // Apply the new font to the renderer and propagate to all terminals.
            // Without synchronizeControllerFontSettings(), per-terminal persisted
            // font settings would override the global config on the next view switch.
            let currentRows = manager.fullRows
            let currentCols = manager.fullCols
            renderer.updateFont(name: fontName, size: fontSize)
            synchronizeControllerFontSettings()
            resizeWindowForFontChange(rows: currentRows, cols: currentCols)

            terminalView?.fontSizeDidChange()
            terminalView?.updateMarkedTextOverlayPublic()
            splitContainerView?.fontSizeDidChange()
            splitContainerView?.updateMarkedTextForFontChange()
        }

        synchronizeWindowLayout(shouldPersistSession: false)
        updateWindowTitle()
    }

    private func makeMenuItem(title: String, shortcut: ShortcutAction) -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: shortcut.appDelegateSelector,
                              keyEquivalent: "")
        applyShortcut(shortcut, to: item)
        return item
    }

    private func applyShortcut(_ shortcut: ShortcutAction, to item: NSMenuItem) {
        let binding = config.shortcuts.binding(for: shortcut).primary
        item.keyEquivalent = binding.menuKeyEquivalent
        item.keyEquivalentModifierMask = binding.modifiers
    }

    // MARK: - Font Size

    private func applyFontSize(_ newSize: CGFloat) {
        // Capture current grid dimensions BEFORE changing font metrics.
        let currentRows = manager.fullRows
        let currentCols = manager.fullCols

        renderer.updateFontSize(newSize)
        synchronizeControllerFontSettings()

        // Resize the window to preserve current rows/cols with the new cell
        // metrics. This avoids changing the grid dimensions, so no SIGWINCH
        // is sent and the shell does not redraw (preventing prompt duplication).
        resizeWindowForFontChange(rows: currentRows, cols: currentCols)

        terminalView?.updateMarkedTextOverlayPublic()
        splitContainerView?.updateMarkedTextForFontChange()
        integratedView?.setNeedsDisplay(integratedView?.bounds ?? .zero)
        updateWindowTitle()
    }

    /// Resize the window so that the given rows/cols fit with the current cell
    /// metrics. The window may extend beyond the visible screen area — this
    /// matches macOS Terminal.app behaviour and ensures rows/cols are preserved
    /// so that no SIGWINCH is sent to the shell.
    private func resizeWindowForFontChange(rows: Int, cols: Int) {
        guard rows > 0, cols > 0 else { return }
        let pad = renderer.gridPadding * 2
        let searchInset = searchBarView == nil ? 0 : Layout.searchBarHeight
        let contentWidth = pad + CGFloat(cols) * renderer.glyphAtlas.cellWidth
        let contentHeight = pad + CGFloat(rows) * renderer.glyphAtlas.cellHeight
            + Layout.statusBarHeight + searchInset
        let contentRect = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        var newFrame = window.frameRect(forContentRect: contentRect)

        // Preserve the top-left corner position (macOS coordinates: origin is
        // bottom-left, so we fix maxY and adjust origin.y).
        let oldFrame = window.frame
        newFrame.origin.x = oldFrame.origin.x
        newFrame.origin.y = oldFrame.maxY - newFrame.height

        window.setFrame(newFrame, display: true, animate: false)
    }

    @objc func fontSizeIncrease(_ sender: Any?) {
        let current = renderer.glyphAtlas.fontSize
        applyFontSize(current + MetalRenderer.fontSizeStep)
    }

    @objc func fontSizeDecrease(_ sender: Any?) {
        let current = renderer.glyphAtlas.fontSize
        applyFontSize(current - MetalRenderer.fontSizeStep)
    }

    @objc func fontSizeReset(_ sender: Any?) {
        applyFontSize(CGFloat(config.fontSize ?? Double(MetalRenderer.defaultFontSize)))
    }

    // MARK: - Window Title

    /// Update the window title based on current view mode.
    private func updateWindowTitle() {
        let newTitle: String
        switch viewMode {
        case .integrated:
            let count = manager.count
            newTitle = "pterm — \(count) terminal(s)"

        case .focused(let controller):
            var parts: [String] = []

            let shellName = ProcessInfo.processInfo.environment["SHELL"]
                .flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "zsh"
            parts.append(shellName)

            let displayTitle = controller.title
            if !displayTitle.isEmpty && displayTitle != "~" {
                parts.append(displayTitle)
            }

            controller.withModel { model in
                parts.append("\(model.cols)×\(model.rows)")
            }

            newTitle = parts.joined(separator: " — ")
        case .split(let controllers):
            newTitle = "pterm — split (\(controllers.count))"
        }
        guard window.title != newTitle else { return }
        window.title = newTitle
    }

    func handleVisibleTerminalTitleChange(for controller: TerminalController) {
        updateWindowTitle()

        switch viewMode {
        case .integrated:
            integratedView?.invalidateDynamicThumbnailCaches()

        case .focused(let focusedController):
            guard focusedController.id == controller.id else { break }
            terminalView?.setNeedsDisplay(terminalView?.bounds ?? .zero)

        case .split(let controllers):
            guard controllers.contains(where: { $0.id == controller.id }) else { break }
            splitContainerView?.requestRender()
        }

        requestSessionPersist()
    }

    // MARK: - Actions

    @objc func newTerminal(_ sender: Any?) {
        let shortcutContext: (workspaceName: String, displayedControllers: [TerminalController])?
        switch viewMode {
        case .focused(let controller):
            shortcutContext = Self.newTerminalShortcutContext(
                focusedController: controller,
                splitControllers: []
            )
        case .split(let controllers):
            shortcutContext = Self.newTerminalShortcutContext(
                focusedController: nil,
                splitControllers: controllers
            )
        case .integrated:
            shortcutContext = nil
        }

        guard let shortcutContext,
              let newController = addNewTerminal(
                workspaceName: shortcutContext.workspaceName,
                startAsynchronously: true
              ) else {
            return
        }
        let effectiveReturnControllers: [TerminalController]?
        switch viewMode {
        case .focused:
            effectiveReturnControllers = controllersAppendingIfNeeded(
                newController,
                to: splitOriginAncestorControllers ?? splitOriginControllers
            )
        case .split(let controllers):
            effectiveReturnControllers = controllersAppendingIfNeeded(
                newController,
                to: splitReturnControllers ?? controllers
            )
        case .integrated:
            effectiveReturnControllers = nil
        }
        switchToSplit(shortcutContext.displayedControllers + [newController], returnToControllers: effectiveReturnControllers)
    }

    @objc func backToIntegratedView(_ sender: Any?) {
        if case .focused = viewMode {
            switchToIntegrated()
        } else if case .split = viewMode {
            switchToIntegrated()
        }
    }

    @objc func closeCurrentTerminal(_ sender: Any?) {
        if case .focused(let controller) = viewMode {
            manager.removeTerminal(controller)
        } else if case .split = viewMode,
                  let controller = splitContainerView?.activeController {
            manager.removeTerminal(controller)
        }
    }

    @objc func focusTerminalByShortcut(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        for (index, action) in ShortcutAction.focusActions.enumerated() where config.shortcuts.matches(action, event: event) {
            focusTerminal(at: index)
            return
        }
    }

    @objc func focusPreviousTerminal(_ sender: Any?) {
        focusAdjacentTerminal(offset: -1)
    }

    @objc func focusNextTerminal(_ sender: Any?) {
        focusAdjacentTerminal(offset: 1)
    }

    @objc func copy(_ sender: Any?) {
        if let textView = window?.firstResponder as? NSTextView,
           textView !== terminalView {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: sender)
            return
        }

        let controller: TerminalController?
        let sourceView: TerminalView?
        switch viewMode {
        case .focused(let focusedController):
            controller = focusedController
            sourceView = terminalView
        case .split:
            controller = splitContainerView?.activeController
            sourceView = splitContainerView?.activeTerminalView
        case .integrated:
            controller = nil
            sourceView = nil
        }
        guard let controller, let sourceView else { return }

        if let text = sourceView.selectedText() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        } else {
            // No selection: send SIGINT (Ctrl+C)
            controller.performInterrupt()
        }
    }

    @objc func paste(_ sender: Any?) {
        if let textView = window?.firstResponder as? NSTextView,
           textView !== terminalView {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
            return
        }

        let controller: TerminalController?
        switch viewMode {
        case .focused(let focusedController):
            controller = focusedController
        case .split:
            controller = splitContainerView?.activeController
        case .integrated:
            controller = nil
        }
        guard let controller else { return }

        let pasteboard = NSPasteboard.general

        // Check for file URLs / image data first — these need to be imported
        // into ~/.pterm/files/ so the managed path is pasted instead of the
        // raw source path, enabling [Image #N] preview tracking.
        do {
            if let result = try clipboardFileStore.importFromPasteboard(pasteboard) {
                pastedImageRegistry.register(createdFiles: result.createdFiles)
                trackPastedImagesPerController(result.createdFiles, controller: controller)
                controller.sendInput(result.textToPaste)
                return
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return
        }

        if let text = pasteboard.string(forType: .string) {
            guard shouldPasteText(text) else { return }

            if controller.model.bracketedPasteMode {
                let sanitized = text.replacingOccurrences(of: "\u{1B}[201~", with: "")
                controller.sendInput("\u{1B}[200~")
                controller.sendInput(sanitized)
                controller.sendInput("\u{1B}[201~")
            } else {
                controller.sendInput(text)
            }
        }
    }

    private func handleTerminalFileDrop(controller: TerminalController, urls: [URL]) -> Bool {
        do {
            guard let result = try clipboardFileStore.importFileURLs(urls) else { return false }
            pastedImageRegistry.register(createdFiles: result.createdFiles)
            trackPastedImagesPerController(result.createdFiles, controller: controller)
            controller.sendInput(result.textToPaste)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Track per-controller image paste order for [Image #N] placeholder lookup.
    /// This does NOT use PastedImageRegistry.indexedImages (which are purged by
    /// Kitty reachability tracking). Instead it maintains a separate per-controller
    /// URL list that is only used for text-placeholder preview.
    private func trackPastedImagesPerController(_ createdFiles: [URL], controller: TerminalController) {
        let imageFiles = createdFiles.filter(PastedImageRegistry.isImageFileURL)
        guard !imageFiles.isEmpty else { return }
        var list = perControllerPastedImages[controller.id] ?? []
        list.append(contentsOf: imageFiles)
        perControllerPastedImages[controller.id] = list
    }

    private func shouldPasteText(_ text: String) -> Bool {
        guard config.security.pasteConfirmation,
              text.contains("\n") || text.contains("\r") else {
            return true
        }

        let alert = NSAlert.pterm()
        alert.messageText = "Paste multi-line text?"
        alert.informativeText = "The text you are pasting contains newlines."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func configureController(_ controller: TerminalController) {
        controller.model.onClipboardWrite = { text in
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }
        controller.model.onClipboardRead = { [weak self] in
            guard let self, self.config.security.osc52ClipboardRead else { return nil }
            if Thread.isMainThread {
                return NSPasteboard.general.string(forType: .string)
            }
            return DispatchQueue.main.sync {
                NSPasteboard.general.string(forType: .string)
            }
        }
        controller.model.mouseReportingPolicy = { [weak self] _, isAlternateScreen in
            guard let self else { return true }
            return !self.config.security.mouseReportRestrictAlternateScreen || isAlternateScreen
        }
        controller.model.onWindowResizeRequest = { [weak self] rows, cols in
            guard let self, self.config.security.allowWindowResizeSequence else { return }
            DispatchQueue.main.async {
                self.resizeWindowToFitTerminal(rows: rows, cols: cols)
            }
        }
        controller.model.onWindowPixelResizeRequest = { [weak self] width, height in
            guard let self, self.config.security.allowWindowResizeSequence else { return }
            DispatchQueue.main.async {
                self.resizeWindowToPixelContent(width: width, height: height)
            }
        }
        controller.onTitleChange = { [weak self, weak controller] _ in
            DispatchQueue.main.async {
                guard let self, let controller else { return }
                self.handleVisibleTerminalTitleChange(for: controller)
            }
        }
        controller.onWorkspaceNameChange = { [weak self, weak controller] _ in
            DispatchQueue.main.async {
                guard let self, let controller else { return }
                self.handleVisibleTerminalTitleChange(for: controller)
            }
        }
        controller.onStateChange = { [weak self] in
            DispatchQueue.main.async {
                self?.requestSessionPersist()
            }
        }
        controller.onInlineImageReachabilityChange = { [weak self] ownerID, liveIndices in
            DispatchQueue.main.async {
                guard let self else { return }
                self.purgeInlineImageResources(ownerID: ownerID, retaining: liveIndices)
            }
        }
        controller.onOutputActivity = { [weak self, weak controller] in
            guard let self, let controller else { return }
            let now = Date()
            // Always track last output time (needed to detect when terminal becomes idle)
            self.lastOutputTimes[controller.id] = now
            self.ensureOutputIdleTimer()
            guard Self.shouldPromoteOutputActivityToVisibleIndicator(
                terminalHasEverBeenIdle: self.terminalsEverIdle.contains(controller.id),
                secondsSinceLastResize: now.timeIntervalSince(self.lastResizeTime)
            ) else {
                return
            }
            self.activeOutputTerminalIDs.insert(controller.id)
            self.syncVisibleTerminalOutputIndicators()
            if Self.shouldTrackIntegratedOverviewActivity(
                presentation: self.currentPresentation,
                appIsActive: NSApp.isActive,
                windowIsVisible: self.window?.occlusionState.contains(.visible) ?? false
            ) {
                self.integratedView?.noteTerminalContentActivity(controller.id)
                self.integratedView?.noteTerminalOutputActivity(controller.id)
            }
        }
        if config.audit.enabled {
            let logger = TerminalAuditLogger(
                sessionID: controller.id,
                termEnv: config.term,
                encryptionEnabled: config.audit.encryption,
                workspaceNameProvider: { [weak controller] in controller?.sessionSnapshot.workspaceName ?? "Uncategorized" },
                terminalNameProvider: { [weak controller] in controller?.title ?? "terminal" },
                sizeProvider: { [weak controller] in
                    guard let controller else { return (80, 24) }
                    return controller.withModel { ($0.cols, $0.rows) }
                }
            )
            try? logger.cleanupExpiredLogs(retentionDays: config.audit.retentionDays)
            controller.auditLogger = logger
        }
    }

    private func ensureOutputIdleTimer() {
        guard outputIdleTimer == nil else { return }
        outputIdleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let now = Date()
            let idleThreshold: TimeInterval = 1.5
            for (id, lastTime) in self.lastOutputTimes {
                if now.timeIntervalSince(lastTime) >= idleThreshold {
                    _ = self.integratedView?.setTerminalOutputActive(id, isActive: false)
                    self.activeOutputTerminalIDs.remove(id)
                    self.syncVisibleTerminalOutputIndicators()
                    self.lastOutputTimes.removeValue(forKey: id)
                    self.terminalsEverIdle.insert(id)
                    if let terminal = self.manager.terminals.first(where: { $0.id == id }),
                       terminal.foregroundProcessID ?? terminal.processID == terminal.processID {
                        _ = terminal.refreshCurrentDirectoryFromShellProcess()
                    }
                }
            }
            if self.lastOutputTimes.isEmpty {
                timer.invalidate()
                self.outputIdleTimer = nil
            }
        }
    }

    private func requestSessionPersist() {
        guard !isTerminating else { return }
        sessionPersistenceCoordinator.schedule()
    }

    private func syncVisibleTerminalOutputIndicators() {
        terminalView?.isOutputActive = focusedController.map {
            activeOutputTerminalIDs.contains($0.id) && !isVisibleOutputIndicatorSuppressed(for: $0.id)
        } ?? false
        let visibleActiveOutputTerminalIDs = Set(
            activeOutputTerminalIDs.filter { !isVisibleOutputIndicatorSuppressed(for: $0) }
        )
        splitContainerView?.setActiveOutputTerminalIDs(visibleActiveOutputTerminalIDs)
    }

    private func suppressVisibleOutputIndicators(for terminalIDs: [UUID], duration: TimeInterval = 1.0) {
        let deadline = Date().addingTimeInterval(duration)
        for id in terminalIDs {
            visibleOutputIndicatorSuppressedUntilByTerminalID[id] = deadline
        }
        scheduleVisibleOutputIndicatorResumeIfNeeded()
        syncVisibleTerminalOutputIndicators()
    }

    private func isVisibleOutputIndicatorSuppressed(for terminalID: UUID) -> Bool {
        guard let deadline = visibleOutputIndicatorSuppressedUntilByTerminalID[terminalID] else {
            return false
        }
        return deadline > Date()
    }

    private func scheduleVisibleOutputIndicatorResumeIfNeeded() {
        visibleOutputIndicatorResumeTimer?.invalidate()
        visibleOutputIndicatorResumeTimer = nil

        let now = Date()
        visibleOutputIndicatorSuppressedUntilByTerminalID =
            visibleOutputIndicatorSuppressedUntilByTerminalID.filter { $0.value > now }
        guard let nextDeadline = visibleOutputIndicatorSuppressedUntilByTerminalID.values.min() else {
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: max(0.01, nextDeadline.timeIntervalSince(now)), repeats: false) {
            [weak self] _ in
            self?.scheduleVisibleOutputIndicatorResumeIfNeeded()
            self?.syncVisibleTerminalOutputIndicators()
        }
        RunLoop.main.add(timer, forMode: .common)
        visibleOutputIndicatorResumeTimer = timer
    }

    private func flushPendingSessionPersistence() {
        guard !Thread.isMainThread else {
            sessionPersistenceCoordinator.flush()
            persistSessionSynchronously()
            return
        }
        DispatchQueue.main.sync { [weak self] in
            self?.sessionPersistenceCoordinator.flush()
            self?.persistSessionSynchronously()
        }
    }

    private func persistSessionAsynchronously() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.persistSessionAsynchronously()
            }
            return
        }
        guard let payload = sessionPersistencePayload() else { return }
        sessionPersistenceQueue.async { [weak self] in
            self?.performSessionPersistence(payload)
        }
    }

    private func persistSessionSynchronously() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { [weak self] in
                self?.persistSessionSynchronously()
            }
            return
        }
        guard let payload = sessionPersistencePayload() else { return }
        sessionPersistenceQueue.sync { [weak self] in
            self?.performSessionPersistence(payload)
        }
    }

    private func sessionPersistencePayload() -> (
        state: PersistedSessionState,
        shouldCleanup: Bool,
        sessionScrollBufferPersistenceEnabled: Bool
    )? {
        guard let window, let manager else { return nil }
        let persistedControllers = manager.terminals.filter { !$0.isTransient }
        let persistedTerminalIDs = Set(persistedControllers.map(\.id))
        let currentPresentation: TerminalListPresentation
        switch viewMode {
        case .integrated:
            currentPresentation = .integrated
        case .focused(let controller):
            currentPresentation = .focused(controller.id)
        case .split(let controllers):
            currentPresentation = .split(controllers.map(\.id))
        }
        let presentationPlan = Self.persistedPresentationPlan(
            currentPresentation: currentPresentation,
            persistedTerminalIDs: persistedTerminalIDs
        )
        let state = PersistedSessionState(
            windowFrame: PersistedWindowFrame(frame: window.frame),
            focusedTerminalID: presentationPlan.focusedTerminalID,
            presentedMode: presentationPlan.mode,
            splitTerminalIDs: presentationPlan.splitTerminalIDs,
            workspaceNames: workspaceNames,
            terminals: persistedControllers.map(\.sessionSnapshot)
        )
        return (state, !isRestoringSession, config.sessionScrollBufferPersistence)
    }

    private func performSessionPersistence(_ payload: (
        state: PersistedSessionState,
        shouldCleanup: Bool,
        sessionScrollBufferPersistenceEnabled: Bool
    )) {
        try? sessionStore.save(payload.state)
        if payload.shouldCleanup {
            cleanupOrphanedScrollbackFiles(
                sessionScrollBufferPersistenceEnabled: payload.sessionScrollBufferPersistenceEnabled,
                retaining: Set(payload.state.terminals.map(\.id))
            )
        }
    }

    private func loadRestorableSession() -> PersistedSessionState? {
        do {
            switch try sessionStore.prepareRestoreDecision() {
            case .none:
                return nil
            case .restore(let session):
                return session
            case .requireUserConfirmation(let session):
                if launchOptions.restoreSessionMode == .force {
                    return session
                }
                if launchOptions.restoreSessionMode == .never {
                    try sessionStore.clearSession()
                    try sessionStore.markCleanShutdown()
                    return nil
                }
                let alert = NSAlert.pterm()
                alert.messageText = "Restore previous session?"
                alert.informativeText = "The previous session did not exit cleanly. Restoring may cause the same issue again."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Restore")
                alert.addButton(withTitle: "Don't Restore")
                if alert.runModal() == .alertFirstButtonReturn {
                    return session
                }
                try sessionStore.clearSession()
                try sessionStore.markCleanShutdown()
                return nil
            }
        } catch {
            try? sessionStore.clearSession()
            try? sessionStore.markCleanShutdown()
            return nil
        }
    }

    private func restoreSession(_ state: PersistedSessionState) {
        isRestoringSession = true
        defer { isRestoringSession = false }
        workspaceNames = state.workspaceNames.map(normalizedWorkspaceName).filter { $0 != WorkspaceNaming.uncategorized }
        syncIntegratedWorkspaceNames()
        var restoredControllers: [UUID: TerminalController] = [:]
        for terminal in state.terminals {
            if let controller = addNewTerminal(
                initialDirectory: terminal.currentDirectory,
                customTitle: terminal.titleOverride,
                workspaceName: normalizedWorkspaceName(terminal.workspaceName),
                textEncoding: terminal.settings?.textEncoding.flatMap(TerminalTextEncoding.init(configuredValue:)),
                fontName: terminal.settings?.fontName,
                fontSize: terminal.settings?.fontSize,
                id: terminal.id
            ) {
                controller.restorePersistedScrollbackToViewport()
                restoredControllers[terminal.id] = controller
            }
        }

        cleanupOrphanedScrollbackFiles(
            sessionScrollBufferPersistenceEnabled: config.sessionScrollBufferPersistence,
            retaining: Set(state.terminals.map(\.id))
        )

        if state.terminals.isEmpty {
            _ = addInitialWorkspaceTerminal()
            switchToIntegrated()
            return
        }

        if state.presentedMode == .split {
            let splitControllers = state.splitTerminalIDs.compactMap { restoredControllers[$0] }
            if splitControllers.count >= 2 {
                switchToSplit(splitControllers)
                return
            }
        }

        if let focusedID = state.focusedTerminalID,
           let controller = restoredControllers[focusedID] {
            switchToFocused(controller)
        } else {
            switchToIntegrated()
        }
    }

    @discardableResult
    private func bootstrapConfiguredWorkspaces() -> Bool {
        guard !config.workspaces.isEmpty else { return false }

        var createdAnyTerminal = false
        workspaceNames = []

        for workspace in config.workspaces {
            let normalizedName = normalizedWorkspaceName(workspace.name)
            ensureWorkspaceExists(named: normalizedName)

            for terminal in workspace.terminals {
                if addNewTerminal(
                    initialDirectory: terminal.initialDirectory,
                    customTitle: terminal.title,
                    workspaceName: normalizedName,
                    textEncoding: terminal.textEncoding,
                    fontName: terminal.fontName,
                    fontSize: terminal.fontSize
                ) != nil {
                    createdAnyTerminal = true
                }
            }
        }

        syncIntegratedWorkspaceNames()
        return createdAnyTerminal || !workspaceNames.isEmpty
    }

    @objc private func exportData(_ sender: Any?) {
        let password = promptPassword(title: "Export Password",
                                      message: "Enter a password to unlock the encrypted note for plaintext export.")
        guard let password else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportImportManager.defaultExportURL().lastPathComponent
        panel.directoryURL = exportImportManager.defaultExportURL().deletingLastPathComponent()
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportImportManager.exportArchive(to: url, password: password)
            showInfoAlert(title: "Export Complete", message: url.path)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func importData(_ sender: Any?) {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.zip]
        openPanel.canChooseDirectories = false
        guard openPanel.runModal() == .OK, let url = openPanel.url else { return }

        let password = promptPassword(title: "Import Password",
                                      message: "Enter a password to re-encrypt the imported note on this Mac.")
        guard let password else { return }

        let preview: PtermExportImportManager.ImportPreview
        do {
            preview = try exportImportManager.inspectArchive(url)
        } catch {
            NSAlert(error: error).runModal()
            return
        }

        let confirm = NSAlert.pterm()
        confirm.messageText = "Proceed with import?"
        let included = preview.includedItems.joined(separator: ", ")
        let overwritten = preview.overwrittenItems.isEmpty
            ? "No items to overwrite"
            : "Overwrite: " + preview.overwrittenItems.joined(separator: ", ")
        confirm.informativeText = "Contents: \(included)\n\(overwritten)"
        confirm.addButton(withTitle: "Import")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        do {
            try exportImportManager.importArchive(from: url, password: password)
            relaunchApplication()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func openSettings(_ sender: Any?) {
        if let existing = settingsController {
            existing.showWindow()
            return
        }
        let controller = SettingsWindowController()
        controller.onClose = { [weak self] in
            self?.settingsController = nil
        }
        settingsController = controller
        controller.showWindow()
    }

    @objc func cut(_ sender: Any?) {
        let activeTerminalInputView: TerminalView? = {
            switch viewMode {
            case .focused:
                return terminalView
            case .split:
                return splitContainerView?.activeTerminalView
            case .integrated:
                return nil
            }
        }()

        if let activeTerminalInputView,
           window?.firstResponder === activeTerminalInputView,
           let text = activeTerminalInputView.cutMarkedText() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return
        }

        guard let textView = window?.firstResponder as? NSTextView,
              textView !== terminalView else {
            return
        }
        NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: sender)
    }

    @objc func newWindowReserved(_ sender: Any?) {
        // Reserved by specification. pterm intentionally remains single-window.
    }

    @objc func undoTextInput(_ sender: Any?) {
        let activeTerminalInputView: TerminalView? = {
            switch viewMode {
            case .focused:
                return terminalView
            case .split:
                return splitContainerView?.activeTerminalView
            case .integrated:
                return nil
            }
        }()

        if let activeTerminalInputView,
           window?.firstResponder === activeTerminalInputView,
           activeTerminalInputView.undoMarkedText() {
            return
        }

        guard let textView = window?.firstResponder as? NSTextView,
              textView !== terminalView else {
            return
        }
        textView.undoManager?.undo()
    }

    private func activeTerminalInteractionTarget() -> (controller: TerminalController, view: TerminalView)? {
        switch viewMode {
        case .focused(let focusedController):
            guard let terminalView else { return nil }
            return (focusedController, terminalView)
        case .split:
            guard let controller = splitContainerView?.activeController,
                  let view = splitContainerView?.activeTerminalView else {
                return nil
            }
            return (controller, view)
        case .integrated:
            return nil
        }
    }

    private func handleHighPriorityInterruptShortcut() -> Bool {
        guard let target = activeTerminalInteractionTarget(),
              window?.firstResponder === target.view else {
            return false
        }
        return target.view.handlePriorityInterruptShortcut()
    }

    @objc func clearActiveTerminalScreen(_ sender: Any?) {
        guard let target = activeTerminalInteractionTarget() else { return }
        target.controller.clearScrollback()
        target.controller.scrollToBottom()
        target.controller.sendInput("\u{0C}")
        target.view.clearSelection()
        (target.view.enclosingScrollView as? TerminalScrollView)?.syncScroller()
        target.view.updateMarkedTextOverlayPublic()
        target.view.needsDisplay = true
    }

    @objc func scrollActiveTerminalToTop(_ sender: Any?) {
        guard let target = activeTerminalInteractionTarget() else { return }
        target.controller.scrollToTop()
        target.view.clearSelection()
        (target.view.enclosingScrollView as? TerminalScrollView)?.syncScroller()
        target.view.updateMarkedTextOverlayPublic()
        target.view.needsDisplay = true
    }

    private func promptPassword(title: String, message: String) -> String? {
        let alert = NSAlert.pterm()
        alert.messageText = title
        alert.informativeText = message
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    @objc private func openClipboardFilesFolder(_ sender: Any?) {
        NSWorkspace.shared.open(PtermDirectories.files)
    }

    @objc private func clearClipboardFiles(_ sender: Any?) {
        let alert = NSAlert.pterm()
        alert.messageText = "Delete clipboard files?"
        alert.informativeText = "All saved files under \(PtermDirectories.files.path) will be deleted."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try clipboardFileStore.deleteAllStoredFiles()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func showInfoAlert(title: String, message: String) {
        let alert = NSAlert.pterm()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func relaunchApplication() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
        NSApp.terminate(nil)
    }

    @objc func selectAll(_ sender: Any?) {
        if let textView = window?.firstResponder as? NSTextView,
           textView !== terminalView {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender)
            return
        }
        switch viewMode {
        case .focused:
            terminalView?.selectAll()
        case .split:
            splitContainerView?.activeTerminalView?.selectAll()
        case .integrated:
            integratedView?.selectAllTerminals()
        }
    }

    private var isOpeningNote = false

    @objc func showAboutPanel() {
        if let existing = aboutController {
            existing.showAboutWindow()
            return
        }
        let controller = AboutWindowController(bundle: .main)
        aboutController = controller
        controller.showAboutWindow()
    }

    @objc func editAppNote(_ sender: Any? = nil) {
        if let existing = appNoteEditor {
            existing.showEditorWindow()
            return
        }
        // Guard against re-entrant calls (e.g., Keychain dialog dispatching events).
        guard !isOpeningNote else { return }
        isOpeningNote = true
        defer { isOpeningNote = false }

        let initialText: String
        do {
            initialText = try appNoteStore.loadNote() ?? ""
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let editorController = MarkdownEditorWindowController(
            initialText: initialText,
            onSave: { [appNoteStore] text in
                try appNoteStore.saveNote(text)
            }
        )
        editorController.onClose = { [weak self] in
            self?.appNoteEditor = nil
        }
        appNoteEditor = editorController
        editorController.showEditorWindow()
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        guard activeSearchTerminalView() != nil else { return }
        showSearchBar()
    }

    @objc func findNextMatch(_ sender: Any?) {
        guard let terminalView = activeSearchTerminalView(),
              let searchBarView else { return }
        let state = terminalView.navigateSearch(forward: true)
        searchBarView.updateCount(current: state.current, total: state.total)
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        guard let terminalView = activeSearchTerminalView(),
              let searchBarView else { return }
        let state = terminalView.navigateSearch(forward: false)
        searchBarView.updateCount(current: state.current, total: state.total)
    }

    private func showSearchBar() {
        if let searchBarView {
            searchBarView.focus()
            return
        }
        guard let terminalView = activeSearchTerminalView() else { return }

        terminalView.beginSearch()
        let bar = SearchBarView(frame: searchBarFrame())
        bar.autoresizingMask = [.width, .minYMargin]
        bar.onQueryChange = { [weak self, weak bar] query in
            guard let self, let terminalView = self.activeSearchTerminalView(),
                  let bar else { return }
            let state = terminalView.updateSearch(query: query)
            bar.updateCount(current: state.current, total: state.total)
        }
        bar.onNavigateNext = { [weak self] in self?.findNextMatch(nil) }
        bar.onClose = { [weak self] in self?.hideSearchBar() }
        searchBarView = bar
        contentHostView().addSubview(bar)
        terminalScrollView?.frame = availableContentFrame()
        bar.focus()
    }

    private func hideSearchBar() {
        terminalView?.endSearch()
        splitContainerView?.activeTerminalView?.endSearch()
        searchBarView?.removeFromSuperview()
        searchBarView = nil
        terminalScrollView?.frame = availableContentFrame()
    }

    private func activeSearchTerminalView() -> TerminalView? {
        switch viewMode {
        case .focused:
            return terminalView
        case .split:
            return splitContainerView?.activeTerminalView
        case .integrated:
            return nil
        }
    }

    private func setupWindowContentHierarchy() {
        let rootView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        rootView.autoresizingMask = [.width, .height]
        rootView.wantsLayer = true

        let hostedContentView = NSView(frame: rootView.bounds)
        hostedContentView.autoresizingMask = [.width, .height]
        hostedContentView.wantsLayer = true
        rootView.addSubview(hostedContentView)

        let presentationHostView = NSView(frame: hostedContentView.bounds)
        presentationHostView.autoresizingMask = [.width, .height]
        presentationHostView.wantsLayer = true
        presentationHostView.layer?.backgroundColor = NSColor.clear.cgColor
        hostedContentView.addSubview(presentationHostView)

        window.contentView = rootView
        windowRootContentView = rootView
        windowHostedContentView = hostedContentView
        windowPresentationHostView = presentationHostView
    }

    private func currentCommandModifierHeld() -> Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
    }

    private func currentCommandIdentityHeadersVisible() -> Bool {
        currentCommandModifierHeld() && !commandIdentityHeaderSuppressedUntilCommandRelease
    }

    private func setCommandIdentityHeadersVisible(_ visible: Bool) {
        let commandHeld = currentCommandModifierHeld()
        terminalView?.setCommandModifierActive(commandHeld)
        terminalView?.setCommandIdentityHeaderVisible(visible)
        splitContainerView?.setCommandModifierActive(commandHeld)
        splitContainerView?.setIdentityHeaderVisible(visible)
    }

    private func refreshStatusBarCommandHints() {
        let multiSelectHint: String?
        let commandClickHint: String?
        switch viewMode {
        case .split:
            multiSelectHint = "Shift+Cmd+Click: Multi-select terminals"
            commandClickHint = splitReturnControllers == nil
                ? "Cmd+Click: Maximize terminal"
                : "Cmd+Click: Return to split"
        case .focused:
            multiSelectHint = nil
            commandClickHint = splitOriginControllers == nil ? nil : "Cmd+Click: Return to split"
        case .integrated:
            multiSelectHint = nil
            commandClickHint = nil
        }
        statusBarView?.setMultiSelectHint(multiSelectHint)
        statusBarView?.setCommandClickHint(commandClickHint)
    }

    /// Inject dependencies for unit tests (only visible via @testable import).
    func configureForTesting(window: NSWindow, renderer: MetalRenderer, manager: TerminalManager, hostedContentView: NSView) {
        self.window = window
        self.renderer = renderer
        self.manager = manager
        self.windowHostedContentView = hostedContentView
        self.statusBarView = StatusBarView(frame: .zero)
        self.manager.onListChanged = { [weak self] in
            self?.handleTerminalListChanged()
        }
    }

    func debugStatusBarCommandClickHintForTesting() -> String? {
        statusBarView.subviews
            .compactMap { $0 as? NSTextField }
            .first(where: { $0.identifier?.rawValue == "statusbar.commandClickHint" && !$0.isHidden })?
            .stringValue
    }

    func debugStatusBarMultiSelectHintForTesting() -> String? {
        statusBarView.subviews
            .compactMap { $0 as? NSTextField }
            .first(where: { $0.identifier?.rawValue == "statusbar.multiSelectHint" && !$0.isHidden })?
            .stringValue
    }

    func debugCurrentFocusedControllerIDForTesting() -> UUID? {
        guard case .focused(let controller) = viewMode else { return nil }
        return controller.id
    }

    func debugCurrentSplitControllerIDsForTesting() -> [UUID]? {
        guard case .split(let controllers) = viewMode else { return nil }
        return controllers.map(\.id)
    }

    func debugSplitReturnControllerIDsForTesting() -> [UUID]? {
        splitReturnControllers?.map(\.id)
    }

    func debugIsIntegratedForTesting() -> Bool {
        if case .integrated = viewMode {
            return true
        }
        return false
    }

    private func contentHostView() -> NSView {
        windowHostedContentView ?? window.contentView!
    }

    private func presentationHostView() -> NSView {
        windowPresentationHostView ?? contentHostView()
    }

    private func normalizeHostedContentFrame() {
        guard let rootView = windowRootContentView else { return }
        windowHostedContentView.frame = rootView.bounds
        windowHostedContentView.autoresizingMask = [.width, .height]
        windowPresentationHostView?.frame = availableContentFrame()
        windowPresentationHostView?.autoresizingMask = [.width, .height]
    }

    @objc private func activateFromSecondaryInstance(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func focusTerminal(at index: Int) {
        guard index >= 0, index < manager.terminals.count else { return }
        switchToFocused(manager.terminals[index])
    }

    private func confirmAndRemoveTerminal(_ controller: TerminalController) {
        let (title, message, confirmTitle) = Self.terminalRemovalConfirmation(
            customTitle: controller.customTitle,
            fallbackTitle: controller.title
        )
        let alert = NSAlert.pterm()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.removeTerminal(controller)
    }

    private func confirmAndRemoveWorkspace(named workspace: String) {
        let normalized = normalizedWorkspaceName(workspace)
        let terminalCount = manager.terminals.filter { $0.sessionSnapshot.workspaceName == normalized }.count
        let (title, message, confirmTitle) = Self.workspaceRemovalConfirmation(
            workspaceName: normalized,
            terminalCount: terminalCount
        )
        let alert = NSAlert.pterm()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        removeWorkspace(named: normalized)
    }

    private func removeWorkspace(named workspace: String) {
        let normalized = normalizedWorkspaceName(workspace)
        let targets = manager.terminals.filter { $0.sessionSnapshot.workspaceName == normalized }
        manager.removeTerminals(targets)
        workspaceNames.removeAll { $0 == normalized }
        syncIntegratedWorkspaceNames()
        requestSessionPersist()
    }

    private func renameWorkspace(from oldName: String, to newName: String) {
        let source = normalizedWorkspaceName(oldName)
        let target = normalizedWorkspaceName(newName)
        guard source != target else { return }
        let targets = manager.terminals.filter { $0.sessionSnapshot.workspaceName == source }
        for controller in targets {
            controller.setWorkspaceName(target)
            handleVisibleTerminalTitleChange(for: controller)
        }
        if let index = workspaceNames.firstIndex(of: source) {
            workspaceNames[index] = target
        }
        workspaceNames = deduplicatedWorkspaceNamesPreservingOrder(workspaceNames)
        syncIntegratedWorkspaceNames()
        requestSessionPersist()
    }

    private func moveTerminal(_ controller: TerminalController, toWorkspace workspace: String) {
        let normalized = normalizedWorkspaceName(workspace)
        controller.setWorkspaceName(normalized)
        handleVisibleTerminalTitleChange(for: controller)
        ensureWorkspaceExists(named: normalized)
        requestSessionPersist()
    }

    static func terminalRemovalConfirmation(
        customTitle: String?,
        fallbackTitle: String
    ) -> (title: String, message: String, confirmButton: String) {
        let trimmedCustomTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveTitle = trimmedCustomTitle.isEmpty
            ? fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedCustomTitle
        let displayTitle = effectiveTitle.isEmpty ? "this terminal" : "\"\(effectiveTitle)\""
        return (
            title: "Remove Terminal?",
            message: "This will stop and remove \(displayTitle) from the overview.",
            confirmButton: "Remove Terminal"
        )
    }

    static func workspaceRemovalConfirmation(
        workspaceName: String,
        terminalCount: Int
    ) -> (title: String, message: String, confirmButton: String) {
        let normalized = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = normalized.isEmpty ? "Uncategorized" : normalized
        let terminalDescription: String
        if terminalCount == 1 {
            terminalDescription = "1 terminal"
        } else {
            terminalDescription = "\(terminalCount) terminals"
        }
        return (
            title: "Remove Workspace?",
            message: "This will stop and remove the workspace \"\(displayName)\" and its \(terminalDescription).",
            confirmButton: "Remove Workspace"
        )
    }

    private func reorderTerminal(_ controller: TerminalController, toWorkspace workspace: String, atIndex index: Int) {
        let normalized = normalizedWorkspaceName(workspace)
        controller.setWorkspaceName(normalized)
        handleVisibleTerminalTitleChange(for: controller)
        ensureWorkspaceExists(named: normalized)
        manager.reorderTerminal(controller, toWorkspace: normalized, atIndex: index)
        requestSessionPersist()
    }

    private func reorderWorkspace(_ name: String, toIndex index: Int) {
        let normalized = normalizedWorkspaceName(name)
        guard let fromIndex = workspaceNames.firstIndex(of: normalized) else { return }
        workspaceNames.remove(at: fromIndex)
        let adjustedIndex = min(index > fromIndex ? index - 1 : index, workspaceNames.count)
        workspaceNames.insert(normalized, at: adjustedIndex)
        syncIntegratedWorkspaceNames()
        requestSessionPersist()
    }

    private func renameTerminalTitle(_ controller: TerminalController, title: String?) {
        controller.setCustomTitle(title)
        requestSessionPersist()
    }

    private func applyInitialFontConfiguration(_ restoredSession: PersistedSessionState?) {
        let configuration = resolveInitialFontConfiguration(restoredSession)
        renderer.updateFont(name: configuration.name, size: configuration.size)
    }

    private func resolveInitialFontConfiguration(_ restoredSession: PersistedSessionState?) -> InitialFontConfiguration {
        let restoredSettings = restoredSession?.terminals.lazy.compactMap(\.settings).first
        let name = config.fontName
            ?? restoredSettings?.fontName
            ?? renderer.glyphAtlas.fontName
        let size = CGFloat(
            config.fontSize
            ?? restoredSettings?.fontSize
            ?? Double(MetalRenderer.defaultFontSize)
        )
        return InitialFontConfiguration(name: name, size: size)
    }

    private func synchronizeControllerFontSettings() {
        let fontName = renderer.glyphAtlas.fontName
        let fontSize = Double(renderer.glyphAtlas.fontSize)
        for controller in manager.terminals {
            controller.updateFontSettings(name: fontName, size: fontSize, notify: false)
        }
        requestSessionPersist()
    }

    private func setupScrollbarOverlay(for iv: IntegratedView) {
        scrollbarOverlay?.removeFromSuperview()
        let overlay = ScrollbarOverlayView(frame: presentationHostView().bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.drawsBackground = false
        overlay.backgroundColor = .clear
        overlay.hasVerticalScroller = true
        overlay.hasHorizontalScroller = false
        overlay.autohidesScrollers = true
        // Flipped document view so scroll starts from the top
        let docView = ScrollDocumentView(frame: NSRect(x: 0, y: 0, width: presentationHostView().bounds.width, height: presentationHostView().bounds.height))
        overlay.documentView = docView
        overlay.contentView.postsBoundsChangedNotifications = true
        presentationHostView().addSubview(overlay)
        iv.companionScrollView = overlay
        scrollbarOverlay = overlay
    }

    private func configureMCPServer() {
        stopMCPServer()
        guard config.mcpServer.enabled else { return }

        do {
            let server = MCPServer(configuration: config.mcpServer, toolProvider: self)
            try server.start()
            mcpServer = server
        } catch {
            mcpServer = nil
            presentMCPServerError(error)
        }
    }

    private func stopMCPServer() {
        mcpServer?.stop()
        mcpServer = nil
    }

    private func presentMCPServerError(_ error: Error) {
        let alert = NSAlert.pterm()
        alert.messageText = "Failed to start MCP server"
        alert.informativeText = "\(error.localizedDescription)\n\nChange the port in Settings > General and try again."
        alert.alertStyle = .critical
        alert.runModal()
    }

    private func terminateApplicationFromMCP() {
        guard !isTerminating else {
            NSApp.terminate(nil)
            return
        }

        isTerminating = true
        flushPendingSessionPersistence()
        clipboardCleanupService?.stop()
        manager.stopAll(
            preserveScrollback: config.sessionScrollBufferPersistence,
            waitForExit: false
        )
        try? sessionStore.markCleanShutdown()
        singleInstanceLock.release()
        stopMCPServer()
        NSApp.terminate(nil)
    }

    private func normalizedWorkspaceName(_ raw: String) -> String {
        FileNameSanitizer.sanitize(raw, fallback: WorkspaceNaming.uncategorized)
    }

    private func ensureWorkspaceExists(named rawName: String) {
        let normalized = normalizedWorkspaceName(rawName)
        guard normalized != WorkspaceNaming.uncategorized else { return }
        if !workspaceNames.contains(normalized) {
            workspaceNames.append(normalized)
            syncIntegratedWorkspaceNames()
        }
    }

    private func deduplicatedWorkspaceNamesPreservingOrder(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(names.count)
        for name in names where !seen.contains(name) {
            seen.insert(name)
            ordered.append(name)
        }
        return ordered
    }

    private func syncIntegratedWorkspaceNames() {
        integratedView?.explicitWorkspaceNames = workspaceNames
    }

    @discardableResult
    private func addInitialWorkspaceTerminal() -> TerminalController? {
        let workspaceName = Self.initialWorkspaceName(existingNames: workspaceNames)
        return addNewTerminal(workspaceName: workspaceName)
    }

    private func promptCreateWorkspace() {
        let alert = NSAlert.pterm()
        alert.messageText = "Add Workspace"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Workspace name"
        field.stringValue = ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                let warn = NSAlert.pterm()
                warn.messageText = "Workspace name cannot be empty."
                warn.alertStyle = .warning
                warn.addButton(withTitle: "OK")
                warn.runModal()
                continue
            }
            let normalized = normalizedWorkspaceName(trimmed)
            guard normalized != WorkspaceNaming.uncategorized else { return }
            ensureWorkspaceExists(named: normalized)
            requestSessionPersist()
            return
        }
    }

    private func cleanupOrphanedScrollbackFiles(
        sessionScrollBufferPersistenceEnabled: Bool,
        retaining ids: Set<UUID>
    ) {
        guard sessionScrollBufferPersistenceEnabled else {
            try? FileManager.default.removeItem(at: PtermDirectories.sessionScrollback)
            PtermDirectories.ensureDirectories()
            return
        }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: PtermDirectories.sessionScrollback,
                                                         includingPropertiesForKeys: nil) else {
            return
        }

        let expected = Set(ids.map { "\($0.uuidString).bin" })
        for url in contents where !expected.contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
    }

    private func focusAdjacentTerminal(offset: Int) {
        guard !manager.terminals.isEmpty else { return }
        let currentIndex: Int
        if case .focused(let controller) = viewMode,
           let found = manager.terminals.firstIndex(where: { $0 === controller }) {
            currentIndex = found
        } else {
            currentIndex = 0
        }

        let nextIndex = (currentIndex + offset + manager.terminals.count) % manager.terminals.count
        switchToFocused(manager.terminals[nextIndex])
    }

    private func resizeWindowToFitTerminal(rows: Int, cols: Int) {
        guard rows > 0, cols > 0 else { return }
        let pad = renderer.gridPadding * 2
        let searchInset = searchBarView == nil ? 0 : Layout.searchBarHeight
        let contentWidth = pad + CGFloat(cols) * renderer.glyphAtlas.cellWidth
        let contentHeight = pad + CGFloat(rows) * renderer.glyphAtlas.cellHeight
            + Layout.statusBarHeight + searchInset
        let contentRect = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        let frameRect = window.frameRect(forContentRect: contentRect)
        window.setFrame(frameRect, display: true, animate: false)
    }

    private func resizeWindowToPixelContent(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let searchInset = searchBarView == nil ? 0 : Layout.searchBarHeight
        let contentRect = NSRect(x: 0,
                                 y: 0,
                                 width: CGFloat(width),
                                 height: CGFloat(height) + Layout.statusBarHeight + searchInset)
        let frameRect = window.frameRect(forContentRect: contentRect)
        window.setFrame(frameRect, display: true, animate: false)
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        lastResizeTime = Date()
        synchronizeWindowLayout(shouldPersistSession: true)
    }

    private func synchronizeWindowLayout(shouldPersistSession: Bool) {
        guard isWindowLayoutReady else { return }

        // Update full-size grid dimensions for all terminals
        let pad = renderer.gridPadding * 2
        layoutTitlebarBackButton()
        statusBarView.frame = statusBarFrame()
        searchBarView?.frame = searchBarFrame()
        windowPresentationHostView?.frame = availableContentFrame()
        let presentationBounds = presentationHostView().bounds
        terminalScrollView?.frame = presentationBounds
        splitContainerView?.frame = presentationBounds
        integratedView?.frame = presentationBounds
        scrollbarOverlay?.frame = presentationBounds
        let contentBounds = availableContentFrame()
        let cols = max(1, Int((contentBounds.width - pad) / renderer.glyphAtlas.cellWidth))
        let rows = max(1, Int((contentBounds.height - pad) / renderer.glyphAtlas.cellHeight))
        manager.updateFullSize(rows: rows, cols: cols)
        updateWindowTitle()
        if shouldPersistSession {
            requestSessionPersist()
        }
    }

    func windowDidMove(_ notification: Notification) {
        requestSessionPersist()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        syncVisibleRenderScaleFactors()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        syncVisibleRenderScaleFactors()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        refreshMetricsMonitoringState()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        stopMetricsMonitor()
        releaseInactiveRenderingResourcesNow()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        refreshMetricsMonitoringState()
        restoreVisibleRenderingResourcesIfNeeded()
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        syncVisibleRenderScaleFactors()
    }

    @objc func applicationDidResignActive(_ notification: Notification) {
        refreshMetricsMonitoringState()
        setCommandIdentityHeadersVisible(currentCommandModifierHeld())
        // Switching to another app should not tear down visible render resources.
        // Doing so forces glyph atlas / buffer reconstruction on the first frame
        // after reactivation, which can expose transient corruption before the
        // next demand-driven redraw settles. We still release on hide/minimize
        // and under memory pressure.
    }

    @objc func applicationDidBecomeActive(_ notification: Notification) {
        refreshMetricsMonitoringState()
        setCommandIdentityHeadersVisible(currentCommandModifierHeld())
        restoreVisibleRenderingResourcesIfNeeded()
    }

    @objc func applicationDidHide(_ notification: Notification) {
        stopMetricsMonitor()
        setCommandIdentityHeadersVisible(currentCommandModifierHeld())
        releaseInactiveRenderingResourcesNow()
    }

    @objc func applicationDidUnhide(_ notification: Notification) {
        refreshMetricsMonitoringState()
        setCommandIdentityHeadersVisible(currentCommandModifierHeld())
        restoreVisibleRenderingResourcesIfNeeded()
    }

    private func syncVisibleRenderScaleFactors() {
        layoutTitlebarBackButton()
        integratedView?.syncScaleFactorIfNeeded()
        terminalView?.syncScaleFactorIfNeeded()
        splitContainerView?.syncScaleFactorIfNeeded()
    }

    private func releaseInactiveRenderingResourcesNow() {
        guard renderer != nil, manager != nil else { return }
        integratedView?.releaseInactiveRenderingResourcesNow()
        terminalView?.releaseInactiveRenderingResourcesNow()
        splitContainerView?.releaseInactiveRenderingResourcesNow()
        for terminal in manager.terminals {
            _ = terminal.debugCompactScrollbackNow()
        }
        _ = renderer.compactIdleGlyphAtlas(maximumInactiveGenerations: 0)
    }

    private func compactForMemoryPressureNow() {
        guard renderer != nil, manager != nil else { return }
        integratedView?.compactForMemoryPressureNow()
        terminalView?.compactForMemoryPressureNow()
        splitContainerView?.compactForMemoryPressureNow()
        for terminal in manager.terminals {
            _ = terminal.debugCompactScrollbackNow()
        }
        _ = renderer.compactIdleGlyphAtlas(maximumInactiveGenerations: 0)
    }

    private func handleMemoryPressure() {
        if NSApplication.shared.isActive, !NSApplication.shared.isHidden, !(window?.isMiniaturized ?? false) {
            compactForMemoryPressureNow()
            restoreVisibleRenderingResourcesIfNeeded()
        } else {
            releaseInactiveRenderingResourcesNow()
        }
    }

    private func restoreVisibleRenderingResourcesIfNeeded() {
        guard renderer != nil else { return }
        syncVisibleRenderScaleFactors()
        integratedView?.setNeedsDisplay(integratedView?.bounds ?? .zero)
        terminalView?.setNeedsDisplay(terminalView?.bounds ?? .zero)
        splitContainerView?.requestRender()
    }

    private func configureWindowAppearance() {
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = false
        let rootView = windowRootContentView ?? window.contentView
        let hostedContentView = contentHostView()
        rootView?.wantsLayer = true
        hostedContentView.wantsLayer = true
        normalizeHostedContentFrame()
        if hostedContentView.superview !== rootView {
            rootView?.addSubview(hostedContentView)
        }
        let usesTranslucentMaterial = Self.shouldUseTranslucentWindowMaterial(
            isIntegratedViewVisible: {
                if case .integrated = viewMode { return true }
                return false
            }(),
            terminalBackgroundOpacity: config.terminalAppearance.normalizedBackgroundOpacity
        )
        let background = config.terminalAppearance.background
        let backgroundColor = NSColor(
            calibratedRed: CGFloat(background.red) / 255.0,
            green: CGFloat(background.green) / 255.0,
            blue: CGFloat(background.blue) / 255.0,
            alpha: 1.0
        )

        if usesTranslucentMaterial {
            if #available(macOS 26.0, *) {
                if windowBackgroundGlassView == nil {
                    let glassView = NSGlassEffectView(frame: rootView?.bounds ?? .zero)
                    glassView.autoresizingMask = [.width, .height]
                    glassView.style = .regular
                    glassView.cornerRadius = 0
                    windowBackgroundGlassView = glassView
                }
                if let glassView = windowBackgroundGlassView as? NSGlassEffectView {
                    glassView.tintColor = nil
                    if let rootView,
                       Self.shouldReinsertSubview(glassView, below: hostedContentView, in: rootView) {
                        rootView.addSubview(glassView, positioned: .below, relativeTo: hostedContentView)
                    }
                    glassView.frame = rootView?.bounds ?? .zero
                    glassView.isHidden = false
                }
            }
            window.isOpaque = false
            window.backgroundColor = .clear
            rootView?.layer?.backgroundColor = NSColor.clear.cgColor
            hostedContentView.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            windowBackgroundGlassView?.removeFromSuperview()
            window.isOpaque = true
            window.backgroundColor = backgroundColor
            rootView?.layer?.backgroundColor = backgroundColor.cgColor
            hostedContentView.layer?.backgroundColor = backgroundColor.cgColor
        }
        statusBarView?.setTranslucentBackground(usesTranslucentMaterial)
    }

    private func applyAppearanceSettingsToVisibleViews() {
        configureWindowAppearance()
        synchronizeWindowLayout(shouldPersistSession: false)
        integratedView?.applyAppearanceSettings()
        terminalView?.applyAppearanceSettings()
        splitContainerView?.applyAppearanceSettings()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // In focused/split view, return to integrated view instead of closing
        if case .focused = viewMode {
            switchToIntegrated()
            return false
        }
        if case .split = viewMode {
            switchToIntegrated()
            return false
        }

        // In integrated view, proceed with close/quit
        let aliveCount = manager.terminals.filter { $0.isAlive }.count
        if aliveCount > 0 {
            let alert = NSAlert.pterm()
            alert.messageText = "Quit pterm?"
            alert.informativeText = "\(aliveCount) terminal(s) are still running."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertSecondButtonReturn {
                return false
            }
        }
        isTerminating = true
        flushPendingSessionPersistence()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        removeBackShortcutMonitor()
        stopConfigWatcher()
        stopMCPServer()
        metricsMonitor?.stop()
        clipboardCleanupService?.stop()
        manager?.stopAll(preserveScrollback: config.sessionScrollBufferPersistence)
        try? sessionStore.markCleanShutdown()
        singleInstanceLock.release()
    }
}

extension AppDelegate: MCPToolProvider {
    func toolDefinitions() -> [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "describe_pterm_model",
                description: "Explain pterm concepts, relationships, identifiers, and recommended MCP workflows for an LLM client.",
                inputSchema: ["type": "object", "properties": [:]]
            ),
            MCPToolDefinition(
                name: "list_state",
                description: "List the full app state: workspace list, workspace-to-terminal relationships, all terminals, and current presentation state.",
                inputSchema: ["type": "object", "properties": [:]]
            ),
            MCPToolDefinition(
                name: "list_workspaces",
                description: "List workspaces only, including each workspace's terminal IDs and counts.",
                inputSchema: ["type": "object", "properties": [:]]
            ),
            MCPToolDefinition(
                name: "list_terminals",
                description: "List all terminals across the app, regardless of workspace.",
                inputSchema: ["type": "object", "properties": [:]]
            ),
            MCPToolDefinition(
                name: "get_terminal",
                description: "Get one terminal with its identifiers, workspace relationship, lifecycle state, and current visible/full text.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "terminal_id": ["type": "string"]
                    ],
                    "required": ["terminal_id"]
                ]
            ),
            MCPToolDefinition(
                name: "create_workspace",
                description: "Create a workspace if it does not already exist.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"]
                    ],
                    "required": ["name"]
                ]
            ),
            MCPToolDefinition(
                name: "rename_workspace",
                description: "Rename a workspace. All terminals in that workspace move with it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "old_name": ["type": "string"],
                        "new_name": ["type": "string"]
                    ],
                    "required": ["old_name", "new_name"]
                ]
            ),
            MCPToolDefinition(
                name: "remove_workspace",
                description: "Remove a workspace and stop/remove all terminals inside it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"]
                    ],
                    "required": ["name"]
                ]
            ),
            MCPToolDefinition(
                name: "create_terminal",
                description: "Create a terminal in a workspace. The returned terminal_id is the primary identifier for later terminal operations. By default this launches the configured shell. If command is provided, launch that executable directly as a transient terminal foreground process in a temporary workspace, focus it immediately, and exclude it from session restore.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "workspace_name": ["type": "string"],
                        "initial_directory": ["type": "string"],
                        "title": ["type": "string"],
                        "command": ["type": "string"],
                        "arguments": [
                            "type": "array",
                            "items": ["type": "string"]
                        ]
                    ]
                ]
            ),
            MCPToolDefinition(
                name: "move_terminal",
                description: "Move a terminal from its current workspace into another workspace.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "terminal_id": ["type": "string"],
                        "workspace_name": ["type": "string"]
                    ],
                    "required": ["terminal_id", "workspace_name"]
                ]
            ),
            MCPToolDefinition(
                name: "rename_terminal",
                description: "Set or clear a terminal custom title.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "terminal_id": ["type": "string"],
                        "title": ["type": "string"]
                    ],
                    "required": ["terminal_id"]
                ]
            ),
            MCPToolDefinition(
                name: "focus_terminal",
                description: "Maximize a terminal into focused view. Recommended before interactive MCP-driven operation so the target terminal is shown at full size instead of the integrated overview.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "terminal_id": ["type": "string"]
                    ],
                    "required": ["terminal_id"]
                ]
            ),
            MCPToolDefinition(
                name: "show_integrated",
                description: "Return to integrated overview mode.",
                inputSchema: ["type": "object", "properties": [:]]
            ),
            MCPToolDefinition(
                name: "send_input",
                description: "Send plain text input to a terminal. For Enter, Escape, arrows, function keys, and control-key actions, prefer send_key instead of embedding control characters in text.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "terminal_id": ["type": "string"],
                        "text": ["type": "string"]
                    ],
                    "required": ["terminal_id", "text"]
                ]
            ),
            MCPToolDefinition(
                name: "send_key",
                description: "Send a named special key to a terminal using terminal-style key semantics. Use this for Enter, Escape, arrows, function keys, and control keys. Use send_input for plain text.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "terminal_id": ["type": "string"],
                        "key": ["type": "string"]
                    ],
                    "required": ["terminal_id", "key"]
                ]
            ),
            MCPToolDefinition(
                name: "interrupt_terminal",
                description: "Send Ctrl+C semantics to a terminal.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "terminal_id": ["type": "string"]
                    ],
                    "required": ["terminal_id"]
                ]
            ),
            MCPToolDefinition(
                name: "clear_scrollback",
                description: "Clear a terminal's scrollback buffer.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "terminal_id": ["type": "string"]
                    ],
                    "required": ["terminal_id"]
                ]
            ),
            MCPToolDefinition(
                name: "refresh_terminal_directory",
                description: "Refresh a terminal's current working directory from the shell process.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "terminal_id": ["type": "string"]
                    ],
                    "required": ["terminal_id"]
                ]
            ),
            MCPToolDefinition(
                name: "capture_terminal",
                description: "Capture the complete and visible text for a terminal.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "terminal_id": ["type": "string"],
                        "include_render_png_path": ["type": "boolean"]
                    ],
                    "required": ["terminal_id"]
                ]
            ),
            MCPToolDefinition(
                name: "wait_for_terminal",
                description: "Wait until a terminal reaches a minimally observable state such as a foreground process, a later screen revision, or output idleness.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "terminal_id": ["type": "string"],
                        "foreground_process_name": ["type": "string"],
                        "screen_revision_gt": ["type": "integer"],
                        "idle_for_ms": ["type": "integer"],
                        "timeout_ms": ["type": "integer"]
                    ],
                    "required": ["terminal_id"]
                ]
            ),
            MCPToolDefinition(
                name: "close_terminal",
                description: "Stop and remove a terminal from the app.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "terminal_id": ["type": "string"]
                    ],
                    "required": ["terminal_id"]
                ]
            ),
            MCPToolDefinition(
                name: "terminate_app",
                description: "Terminate the pterm application.",
                inputSchema: ["type": "object", "properties": [:]]
            )
        ]
    }

    func callTool(named name: String, arguments: [String: Any]) throws -> String {
        let payload: Any

        switch name {
        case "describe_pterm_model":
            payload = mcpModelDescriptionPayload()
        case "list_state":
            payload = mcpStatePayload()
        case "list_workspaces":
            payload = [
                "workspaces": mcpWorkspacePayloads(),
                "note": "Each workspace contains zero or more terminal_ids. Use list_terminals or get_terminal for terminal details."
            ]
        case "list_terminals":
            payload = [
                "terminals": manager.terminals.map(mcpTerminalPayload(for:)),
                "presentation": mcpPresentationPayload()
            ]
        case "get_terminal":
            let controller = try mcpTerminal(from: arguments)
            payload = mcpTerminalDetailsPayload(for: controller)
        case "create_workspace":
            guard let workspaceName = arguments["name"] as? String,
                  !workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPServerError.invalidRequest
            }
            ensureWorkspaceExists(named: workspaceName)
            requestSessionPersist()
            payload = mcpStatePayload()
        case "rename_workspace":
            guard let oldName = arguments["old_name"] as? String,
                  let newName = arguments["new_name"] as? String else {
                throw MCPServerError.invalidRequest
            }
            renameWorkspace(from: oldName, to: newName)
            payload = mcpStatePayload()
        case "remove_workspace":
            guard let workspaceName = arguments["name"] as? String else {
                throw MCPServerError.invalidRequest
            }
            removeWorkspace(named: workspaceName)
            payload = mcpStatePayload()
        case "create_terminal":
            let initialDirectory = arguments["initial_directory"] as? String
            let title = arguments["title"] as? String
            let command = arguments["command"] as? String
            let executableArguments = arguments["arguments"] as? [String] ?? []
            let terminalID = UUID()
            let isDirectLaunch = command != nil
            let workspaceName = if let command {
                Self.transientWorkspaceName(commandPath: command, id: terminalID)
            } else {
                (arguments["workspace_name"] as? String) ?? WorkspaceNaming.uncategorized
            }
            guard let controller = addNewTerminal(
                initialDirectory: initialDirectory,
                executablePath: command,
                executableArguments: executableArguments,
                isTransient: isDirectLaunch,
                customTitle: title,
                workspaceName: workspaceName,
                id: terminalID,
                startAsynchronously: true
            ) else {
                throw MCPServerError.invalidRequest
            }
            if isDirectLaunch {
                switchToFocused(controller)
            }
            payload = [
                "terminal": mcpTerminalPayload(for: controller),
                "state": mcpStatePayload()
            ]
        case "move_terminal":
            let controller = try mcpTerminal(from: arguments)
            guard let workspaceName = arguments["workspace_name"] as? String else {
                throw MCPServerError.invalidRequest
            }
            moveTerminal(controller, toWorkspace: workspaceName)
            payload = [
                "terminal": mcpTerminalPayload(for: controller),
                "state": mcpStatePayload()
            ]
        case "rename_terminal":
            let controller = try mcpTerminal(from: arguments)
            let title = arguments["title"] as? String
            renameTerminalTitle(controller, title: title)
            payload = mcpTerminalDetailsPayload(for: controller)
        case "focus_terminal":
            let controller = try mcpTerminal(from: arguments)
            switchToFocused(controller)
            payload = [
                "focused_terminal_id": controller.id.uuidString,
                "state": mcpStatePayload()
            ]
        case "show_integrated":
            switchToIntegrated()
            payload = mcpStatePayload()
        case "send_input":
            let controller = try mcpTerminal(from: arguments)
            guard let text = arguments["text"] as? String else {
                throw MCPServerError.invalidRequest
            }
            controller.sendInput(text)
            payload = [
                "terminal_id": controller.id.uuidString,
                "sent": text
            ]
        case "send_key":
            let controller = try mcpTerminal(from: arguments)
            guard let key = arguments["key"] as? String,
                  let action = KeyboardHandler.mcpKeyAction(named: key, controller: controller) else {
                throw MCPServerError.invalidRequest
            }
            switch action {
            case .input(let text):
                controller.sendInput(text)
            case .interrupt(let controlCharacter):
                controller.performInterrupt(controlCharacter: controlCharacter)
            }
            payload = [
                "terminal_id": controller.id.uuidString,
                "key": key
            ]
        case "interrupt_terminal":
            let controller = try mcpTerminal(from: arguments)
            controller.performInterrupt()
            payload = [
                "terminal_id": controller.id.uuidString,
                "action": "interrupt_sent"
            ]
        case "clear_scrollback":
            let controller = try mcpTerminal(from: arguments)
            controller.clearScrollback()
            payload = [
                "terminal_id": controller.id.uuidString,
                "action": "scrollback_cleared"
            ]
        case "refresh_terminal_directory":
            let controller = try mcpTerminal(from: arguments)
            let refreshed = controller.refreshCurrentDirectoryFromShellProcess()
            payload = [
                "terminal_id": controller.id.uuidString,
                "refreshed": refreshed,
                "terminal": mcpTerminalPayload(for: controller)
            ]
        case "capture_terminal":
            let controller = try mcpTerminal(from: arguments)
            payload = mcpTerminalDetailsPayload(
                for: controller,
                includeRenderPNGPath: (arguments["include_render_png_path"] as? Bool) == true
            )
        case "wait_for_terminal":
            let condition = try MCPTerminalWaitCondition(arguments: arguments)
            payload = try waitForTerminal(condition)
        case "close_terminal":
            let controller = try mcpTerminal(from: arguments)
            let terminalID = controller.id.uuidString
            manager.removeTerminal(controller)
            payload = [
                "closed_terminal_id": terminalID,
                "state": mcpStatePayload()
            ]
        case "terminate_app":
            payload = [
                "terminating": true
            ]
            DispatchQueue.main.async {
                self.terminateApplicationFromMCP()
            }
        default:
            throw MCPServerError.toolNotFound(name)
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func mcpTerminal(from arguments: [String: Any]) throws -> TerminalController {
        guard let rawID = arguments["terminal_id"] as? String,
              let id = UUID(uuidString: rawID),
              let controller = manager.terminals.first(where: { $0.id == id }) else {
            throw MCPServerError.invalidRequest
        }
        return controller
    }

    private func mcpStatePayload() -> [String: Any] {
        [
            "mcp_server": [
                "enabled": config.mcpServer.enabled,
                "port": config.mcpServer.port
            ],
            "relationships": [
                "workspace_to_terminals": "Each workspace contains zero or more terminals.",
                "terminal_to_workspace": "Each terminal belongs to exactly one workspace.",
                "terminal_id_usage": "Use terminal_id for terminal operations such as focus, send_input, capture_terminal, close_terminal, rename_terminal, move_terminal, interrupt_terminal, clear_scrollback."
            ],
            "presentation": mcpPresentationPayload(),
            "workspaces": mcpWorkspacePayloads(),
            "terminals": manager.terminals.map(mcpTerminalPayload(for:))
        ]
    }

    private func mcpModelDescriptionPayload() -> [String: Any] {
        [
            "concepts": [
                [
                    "name": "workspace",
                    "description": "A logical group of terminals shown in the integrated overview.",
                    "identifier": "workspace name"
                ],
                [
                    "name": "terminal",
                    "description": "A live terminal session. Every terminal belongs to exactly one workspace.",
                    "identifier": "terminal_id"
                ],
                [
                    "name": "presentation",
                    "description": "The current app view mode: integrated, focused, or split."
                ]
            ],
            "relationships": [
                "A workspace contains zero or more terminals.",
                "A terminal belongs to exactly one workspace.",
                "The app also has a global terminal list that spans all workspaces.",
                "For MCP-driven input, use send_input for plain text and send_key for Enter and other non-text keys."
            ],
            "recommended_workflows": [
                [
                    "goal": "Understand the current app state",
                    "steps": ["call describe_pterm_model", "call list_state"]
                ],
                [
                    "goal": "Create and operate a terminal in a workspace",
                    "steps": ["call create_workspace if needed", "call create_terminal", "call focus_terminal before interactive work", "use send_input only for plain text", "use send_key for Enter, Escape, arrows, function keys, and control-key actions", "use wait_for_terminal and capture_terminal to observe progress", "call show_integrated when you want to return to the overview"]
                ],
                [
                    "goal": "Inspect one terminal in detail",
                    "steps": ["call focus_terminal when visual size matters", "call get_terminal or capture_terminal with terminal_id"]
                ],
                [
                    "goal": "Move or reorganize terminals",
                    "steps": ["call move_terminal, rename_terminal, rename_workspace, or remove_workspace"]
                ]
            ],
            "interaction_guidance": [
                "The integrated overview is useful for global state and navigation, but each terminal is smaller there.",
                "Before interactive MCP-driven work such as shells, REPLs, full-screen TUIs, or CLI agents, prefer focus_terminal so the target terminal is shown at full size.",
                "Use send_input only for plain text.",
                "For Enter and other non-text input, prefer send_key. Do not rely on embedding newline or escape characters inside send_input when precise key semantics matter.",
                "Use show_integrated when you are done and want to return to the overview."
            ],
            "available_tools": toolDefinitions().map(\.name)
        ]
    }

    private func mcpWorkspacePayloads() -> [[String: Any]] {
        let explicitNames = workspaceNames
        let discoveredNames = manager.terminals.map { $0.sessionSnapshot.workspaceName }
        let orderedNames = deduplicatedWorkspaceNamesPreservingOrder(explicitNames + discoveredNames)

        return orderedNames.map { workspaceName in
            let terminals = manager.terminals.filter { $0.sessionSnapshot.workspaceName == workspaceName }
            return [
                "name": workspaceName,
                "terminal_count": terminals.count,
                "terminal_ids": terminals.map { $0.id.uuidString }
            ]
        }
    }

    private func mcpPresentationPayload() -> [String: Any] {
        switch viewMode {
        case .integrated:
            return ["mode": "integrated"]
        case .focused(let controller):
            return [
                "mode": "focused",
                "terminal_id": controller.id.uuidString
            ]
        case .split(let controllers):
            return [
                "mode": "split",
                "terminal_ids": controllers.map { $0.id.uuidString }
            ]
        }
    }

    private func mcpTerminalPayload(for controller: TerminalController) -> [String: Any] {
        let snapshot = controller.sessionSnapshot
        return [
            "id": controller.id.uuidString,
            "title": controller.title,
            "custom_title": controller.customTitle ?? NSNull(),
            "workspace_name": snapshot.workspaceName,
            "is_transient": controller.isTransient,
            "current_directory": snapshot.currentDirectory,
            "is_alive": controller.isAlive,
            "foreground_process_id": controller.foregroundProcessID.map { Int($0) } ?? NSNull(),
            "foreground_process_name": controller.foregroundProcessName ?? NSNull(),
            "screen_revision": controller.screenRevision,
            "last_output_at": Self.mcpTimestampString(controller.lastOutputAt)
        ]
    }

    private func mcpTerminalDetailsPayload(
        for controller: TerminalController,
        includeRenderPNGPath: Bool = false
    ) -> [String: Any] {
        let snapshot = controller.captureRenderSnapshot()
        var payload: [String: Any] = [
            "terminal": mcpTerminalPayload(for: controller),
            "all_text": controller.allText(),
            "rows": snapshot.rows,
            "cols": snapshot.cols,
            "visible_text": Self.mcpVisibleText(from: snapshot, trimWhitespace: true),
            "visible_text_raw": Self.mcpVisibleText(from: snapshot, trimWhitespace: false),
            "visible_text_ansi": Self.mcpVisibleTextANSI(from: snapshot, trimWhitespace: true),
            "visible_text_ansi_raw": Self.mcpVisibleTextANSI(from: snapshot, trimWhitespace: false)
        ]
        if let viewportGeometry = mcpViewportGeometryPayload(for: controller) {
            payload["viewport_geometry"] = viewportGeometry
        }
        if includeRenderPNGPath,
           let renderPNGPath = mcpRenderedTerminalImagePath(for: controller) {
            payload["render_png_path"] = renderPNGPath
        }
        return payload
    }

    private func mcpRenderedTerminalImagePath(for controller: TerminalController) -> String? {
        guard let target = activeTerminalInteractionTarget(),
              target.controller.id == controller.id,
              let pngData = target.view.debugRenderedPNGDataForTesting() else {
            return nil
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pterm-mcp-captures", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("\(controller.id.uuidString)-render.png")
            try pngData.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            return nil
        }
    }

    private func mcpViewportGeometryPayload(for controller: TerminalController) -> [String: Any]? {
        guard let target = activeTerminalInteractionTarget(),
              target.controller.id == controller.id,
              let window = target.view.window,
              let screen = window.screen else {
            return nil
        }

        let visibleRect = target.view.visibleRect
        guard !visibleRect.isEmpty else { return nil }

        let rectInWindow = target.view.convert(visibleRect, to: nil)
        let contentFrameInWindow = window.contentView?.frame ?? .zero
        let rectInWindowTopLeft = CGRect(
            x: contentFrameInWindow.minX + rectInWindow.minX,
            y: window.frame.height - (contentFrameInWindow.minY + rectInWindow.maxY),
            width: rectInWindow.width,
            height: rectInWindow.height
        ).integral
        let rectInScreen = window.convertToScreen(rectInWindow)
        let cgRect = CGRect(
            x: rectInScreen.minX,
            y: screen.frame.maxY - rectInScreen.maxY,
            width: rectInScreen.width,
            height: rectInScreen.height
        ).integral

        guard cgRect.width > 0, cgRect.height > 0 else { return nil }

        return [
            "window_number": Int(window.windowNumber),
            "scale_factor": window.backingScaleFactor,
            "viewport_rect_in_window_cg": [
                "x": rectInWindowTopLeft.origin.x,
                "y": rectInWindowTopLeft.origin.y,
                "width": rectInWindowTopLeft.width,
                "height": rectInWindowTopLeft.height
            ],
            "screen_rect_cg": [
                "x": cgRect.origin.x,
                "y": cgRect.origin.y,
                "width": cgRect.width,
                "height": cgRect.height
            ]
        ]
    }

    static func mcpVisibleText(
        from snapshot: TerminalController.RenderSnapshot,
        trimWhitespace: Bool
    ) -> String {
        snapshot.visibleRows
            .map { mcpVisibleRowText(from: $0, trimWhitespace: trimWhitespace) }
            .joined(separator: "\n")
    }

    static func mcpVisibleTextANSI(
        from snapshot: TerminalController.RenderSnapshot,
        trimWhitespace: Bool
    ) -> String {
        snapshot.visibleRows
            .map { mcpVisibleRowTextANSI(from: $0, trimWhitespace: trimWhitespace) }
            .joined(separator: "\n")
    }

    private static func mcpVisibleRowText(
        from row: TerminalController.RenderRowSnapshot,
        trimWhitespace: Bool
    ) -> String {
        let bounds = mcpVisibleRowBounds(in: row.cells, trimWhitespace: trimWhitespace)
        guard bounds.lowerBound < bounds.upperBound else { return "" }

        var output = ""
        output.reserveCapacity(bounds.count)
        for cell in row.cells[bounds] {
            guard let rendered = mcpRenderedVisibleText(for: cell) else { continue }
            output.append(rendered)
        }
        return output
    }

    private static func mcpVisibleRowTextANSI(
        from row: TerminalController.RenderRowSnapshot,
        trimWhitespace: Bool
    ) -> String {
        let bounds = mcpVisibleRowBounds(in: row.cells, trimWhitespace: trimWhitespace)
        guard bounds.lowerBound < bounds.upperBound else { return "" }

        var output = ""
        var currentAttributes = CellAttributes.default
        var needsReset = false

        for cell in row.cells[bounds] {
            guard let rendered = mcpRenderedVisibleText(for: cell) else { continue }
            let attributes = cell.attributes
            if attributes != currentAttributes {
                output.append(mcpANSITransition(from: currentAttributes, to: attributes))
                currentAttributes = attributes
                needsReset = attributes != .default
            }
            output.append(rendered)
        }

        if needsReset {
            output.append("\u{001B}[m")
        }
        return output
    }

    private static func mcpVisibleRowBounds(in cells: [Cell], trimWhitespace: Bool) -> Range<Int> {
        guard trimWhitespace else { return cells.startIndex..<cells.endIndex }

        var lowerBound = cells.startIndex
        while lowerBound < cells.endIndex, mcpCellIsTrimmedWhitespace(cells[lowerBound]) {
            lowerBound += 1
        }

        var upperBound = cells.endIndex
        while upperBound > lowerBound, mcpCellIsTrimmedWhitespace(cells[upperBound - 1]) {
            upperBound -= 1
        }
        return lowerBound..<upperBound
    }

    private static func mcpCellIsTrimmedWhitespace(_ cell: Cell) -> Bool {
        guard let rendered = mcpRenderedVisibleText(for: cell) else { return true }
        return rendered == " "
    }

    private static func mcpRenderedVisibleText(for cell: Cell) -> String? {
        guard !cell.isWideContinuation, !cell.hasInlineImage else { return nil }
        let rendered = cell.renderedString()
        return rendered.isEmpty ? " " : rendered
    }

    private static func mcpANSITransition(from _: CellAttributes, to target: CellAttributes) -> String {
        if target == .default {
            return "\u{001B}[m"
        }

        var params: [String] = ["0"]
        if target.bold { params.append("1") }
        if target.dim { params.append("2") }
        if target.italic { params.append("3") }
        if target.underline {
            switch target.underlineStyle {
            case .single:
                params.append("4")
            case .double:
                params.append("4:2")
            case .curly:
                params.append("4:3")
            case .dotted:
                params.append("4:4")
            case .dashed:
                params.append("4:5")
            }
        }
        if target.blink { params.append("5") }
        if target.inverse { params.append("7") }
        if target.hidden { params.append("8") }
        if target.strikethrough { params.append("9") }
        params.append(contentsOf: mcpANSIColorParameters(for: target.foreground, role: .foreground))
        params.append(contentsOf: mcpANSIColorParameters(for: target.background, role: .background))
        params.append(contentsOf: mcpANSIColorParameters(for: target.underlineColor, role: .underline))
        return "\u{001B}[\(params.joined(separator: ";"))m"
    }

    private enum MCPANSIColorRole {
        case foreground
        case background
        case underline
    }

    private static func mcpANSIColorParameters(for color: TerminalColor, role: MCPANSIColorRole) -> [String] {
        switch color {
        case .default:
            switch role {
            case .foreground:
                return ["39"]
            case .background:
                return ["49"]
            case .underline:
                return ["59"]
            }
        case .indexed(let index):
            switch role {
            case .foreground:
                if index < 8 { return ["\(30 + index)"] }
                if index < 16 { return ["\(90 + (index - 8))"] }
                return ["38", "5", "\(index)"]
            case .background:
                if index < 8 { return ["\(40 + index)"] }
                if index < 16 { return ["\(100 + (index - 8))"] }
                return ["48", "5", "\(index)"]
            case .underline:
                return ["58", "5", "\(index)"]
            }
        case .rgb(let r, let g, let b):
            switch role {
            case .foreground:
                return ["38", "2", "\(r)", "\(g)", "\(b)"]
            case .background:
                return ["48", "2", "\(r)", "\(g)", "\(b)"]
            case .underline:
                return ["58", "2", "\(r)", "\(g)", "\(b)"]
            }
        }
    }

    private func mcpObservation(for controller: TerminalController) -> MCPTerminalObservation {
        MCPTerminalObservation(
            terminalID: controller.id,
            foregroundProcessName: controller.foregroundProcessName,
            screenRevision: controller.screenRevision,
            lastOutputAt: controller.lastOutputAt
        )
    }

    private func waitForTerminal(_ condition: MCPTerminalWaitCondition) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(Double(condition.timeoutMilliseconds) / 1000.0)
        let pollInterval: TimeInterval = 0.1

        while true {
            guard let controller = manager.terminals.first(where: { $0.id == condition.terminalID }) else {
                throw MCPServerError.invalidRequest
            }

            let observation = mcpObservation(for: controller)
            let now = Date()
            if condition.isSatisfied(by: observation, now: now) {
                return [
                    "matched": true,
                    "timed_out": false,
                    "terminal": mcpTerminalPayload(for: controller)
                ]
            }
            if now >= deadline {
                return [
                    "matched": false,
                    "timed_out": true,
                    "terminal": mcpTerminalPayload(for: controller)
                ]
            }

            let nextWake = min(deadline, now.addingTimeInterval(pollInterval))
            RunLoop.current.run(mode: .default, before: nextWake)
        }
    }

    private static func mcpTimestampString(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return mcpDateFormatter.string(from: date)
    }
}

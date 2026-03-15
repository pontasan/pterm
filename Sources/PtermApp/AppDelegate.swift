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
    private static let supportedModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isBackToIntegratedShortcut(event) {
            onBackToIntegratedShortcut?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
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

    private var statusBarView: StatusBarView!
    private var windowBackgroundGlassView: NSView?
    private var windowRootContentView: NSView!
    private var windowHostedContentView: NSView!
    private var windowPresentationHostView: NSView!
    private var configWatchSource: DispatchSourceFileSystemObject?
    private var pendingConfigReload: DispatchWorkItem?
    private var backShortcutMonitor: Any?
    private var titlebarBackButton: NSButton?

    private var metricsMonitor: ProcessMetricsMonitor?
    /// Tracks last output time per terminal for active-output indicator.
    private var lastOutputTimes: [UUID: Date] = [:]
    private var outputIdleTimer: Timer?
    private var activeOutputTerminalIDs: Set<UUID> = []
    private var visibleOutputIndicatorSuppressedUntilByTerminalID: [UUID: Date] = [:]
    private var visibleOutputIndicatorResumeTimer: Timer?
    /// Suppresses active-output indicator briefly after resize.
    private var lastResizeTime: Date = .distantPast
    /// Tracks terminals that have been idle at least once (initial output burst is over).
    private var terminalsEverIdle: Set<UUID> = []
    private let clipboardFileStore = ClipboardFileStore()
    private let pastedImageRegistry = PastedImageRegistry()
    private var clipboardCleanupService: ClipboardCleanupService?
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
        window = appWindow
        window.center()
        window.title = "pterm"
        window.minSize = NSSize(width: 400, height: 300)
        window.delegate = self
        window.isRestorable = false // Disable macOS state restoration
        setupWindowContentHierarchy()
        installTitlebarBackButton()

        configureWindowAppearance()

        let restoredSession = loadRestorableSession()
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
        contentHostView().addSubview(statusBarView)

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

        // Setup menu
        setupMenu()
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
        return .terminateNow
    }

    // MARK: - Terminal Management

    @discardableResult
    private func addNewTerminal(initialDirectory: String? = nil,
                                customTitle: String? = nil,
                                workspaceName: String = "Uncategorized",
                                textEncoding: TerminalTextEncoding? = nil,
                                fontName: String? = nil,
                                fontSize: Double? = nil,
                                id: UUID = UUID(),
                                startAsynchronously: Bool = false) -> TerminalController? {
        ensureWorkspaceExists(named: workspaceName)
        do {
            let controller = try manager.addTerminal(
                initialDirectory: initialDirectory,
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
        lastOutputTimes = lastOutputTimes.filter { remainingTerminalIDs.contains($0.key) }
        terminalsEverIdle = terminalsEverIdle.intersection(remainingTerminalIDs)
        activeOutputTerminalIDs = activeOutputTerminalIDs.intersection(remainingTerminalIDs)
        visibleOutputIndicatorSuppressedUntilByTerminalID =
            visibleOutputIndicatorSuppressedUntilByTerminalID.filter { remainingTerminalIDs.contains($0.key) }
        scheduleVisibleOutputIndicatorResumeIfNeeded()
        syncVisibleTerminalOutputIndicators()

        let wasIntegrated = {
            if case .integrated = viewMode { return true }
            return false
        }()

        let currentPresentation: TerminalListPresentation
        switch viewMode {
        case .integrated:
            currentPresentation = .integrated
        case .focused(let controller):
            currentPresentation = .focused(controller.id)
        case .split(let controllers):
            currentPresentation = .split(controllers.map(\.id))
        }

        let nextPresentation = Self.reconcilePresentationAfterTerminalListChange(
            currentPresentation: currentPresentation,
            remainingTerminalIDs: manager.terminals.map(\.id)
        )

        switch nextPresentation {
        case .integrated:
            if case .integrated = viewMode {
                break
            }
            switchToIntegrated()
        case .focused(let id):
            guard let controller = manager.terminals.first(where: { $0.id == id }) else {
                switchToIntegrated()
                break
            }
            switchToFocused(controller)
        case .split(let ids):
            let controllers = ids.compactMap { id in
                manager.terminals.first(where: { $0.id == id })
            }
            if controllers.count >= 2 {
                switchToSplit(controllers)
            } else if let first = controllers.first {
                switchToFocused(first)
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

    // MARK: - View Switching

    private func switchToFocused(_ controller: TerminalController) {
        Self.refreshCurrentDirectories(for: [controller])
        applyRendererSettings(for: controller)

        // Create focused terminal view wrapped in scroll view
        let sv = TerminalScrollView(frame: presentationHostView().bounds, renderer: renderer)
        sv.autoresizingMask = [.width, .height]
        sv.shortcutConfiguration = config.shortcuts
        sv.terminalView.outputConfirmedInputAnimationsEnabled = config.textInteraction.outputConfirmedInputAnimation
        sv.terminalView.typewriterSoundEnabled = config.textInteraction.typewriterSoundEnabled
        sv.terminalView.terminalController = controller
        sv.terminalView.imagePreviewURLProvider = { [weak self] index in
            self?.pastedImageRegistry.url(forPlaceholderIndex: index)
        }
        sv.terminalView.onBackToIntegrated = { [weak self] in
            self?.switchToIntegrated()
        }
        sv.terminalView.onCmdClick = { [weak self] in
            guard let self, let controllers = self.splitOriginControllers else { return }
            self.splitOriginControllers = nil
            self.switchToSplit(controllers)
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
        suppressVisibleOutputIndicators(for: [controller.id])
        terminalView?.applyAppearanceSettings()
        focusedController = controller

        viewMode = .focused(controller)
        applyAppearanceSettingsToVisibleViews()
        updateTitlebarBackButtonVisibility()
        refreshMetricsMonitoringState()
        refreshStatusBarMetrics()
        window.makeFirstResponder(sv.terminalView)
        sv.terminalView.syncScaleFactorIfNeeded()

        updateWindowTitle()
        requestSessionPersist()
    }

    private func switchToSplit(_ controllers: [TerminalController]) {
        guard controllers.count >= 2 else {
            if let first = controllers.first {
                switchToFocused(first)
            } else {
                switchToIntegrated()
            }
            return
        }

        Self.refreshCurrentDirectories(for: controllers)

        let splitView = SplitTerminalContainerView(frame: presentationHostView().bounds,
                                                   renderer: renderer,
                                                   controllers: controllers)
        splitView.autoresizingMask = [.width, .height]
        splitView.shortcutConfiguration = config.shortcuts
        splitView.outputConfirmedInputAnimationsEnabled = config.textInteraction.outputConfirmedInputAnimation
        splitView.typewriterSoundEnabled = config.textInteraction.typewriterSoundEnabled
        splitView.imagePreviewURLProvider = { [weak self] index in
            self?.pastedImageRegistry.url(forPlaceholderIndex: index)
        }
        splitView.onActiveControllerChange = { [weak self] controller in
            self?.applyRendererSettings(for: controller)
        }
        splitView.onBackToIntegrated = { [weak self] in
            self?.switchToIntegrated()
        }
        splitView.onMaximizeTerminal = { [weak self] controller in
            guard let self else { return }
            self.splitOriginControllers = controllers
            self.switchToFocused(controller)
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
        suppressVisibleOutputIndicators(for: controllers.map(\.id))
        splitContainerView?.applyAppearanceSettings()
        splitOriginControllers = nil
        viewMode = .split(controllers)
        applyAppearanceSettingsToVisibleViews()
        updateTitlebarBackButtonVisibility()
        refreshMetricsMonitoringState()
        refreshStatusBarMetrics()
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
        hideSearchBar()

        viewMode = .integrated
        applyAppearanceSettingsToVisibleViews()
        iv.syncScaleFactorIfNeeded()
        updateTitlebarBackButtonVisibility()
        refreshMetricsMonitoringState()
        refreshStatusBarMetrics()
        window.makeFirstResponder(iv)

        updateWindowTitle()
        requestSessionPersist()
    }

    private func makeIntegratedView(frame: NSRect) -> IntegratedView {
        let iv = IntegratedView(frame: frame, renderer: renderer, manager: manager)
        iv.autoresizingMask = [.width, .height]
        iv.shortcutConfiguration = config.shortcuts
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

    private func reloadConfigurationFromDisk() {
        config = PtermConfigStore.load()
        TypewriterSoundPlayer.shared.configure(enabled: config.textInteraction.typewriterSoundEnabled)
        manager.updateConfiguration(config)
        setupMenu()
        terminalView?.shortcutConfiguration = config.shortcuts
        terminalView?.outputConfirmedInputAnimationsEnabled = config.textInteraction.outputConfirmedInputAnimation
        terminalView?.typewriterSoundEnabled = config.textInteraction.typewriterSoundEnabled
        splitContainerView?.shortcutConfiguration = config.shortcuts
        splitContainerView?.outputConfirmedInputAnimationsEnabled = config.textInteraction.outputConfirmedInputAnimation
        splitContainerView?.typewriterSoundEnabled = config.textInteraction.typewriterSoundEnabled
        integratedView?.shortcutConfiguration = config.shortcuts
        renderer.updateTerminalAppearance(config.terminalAppearance)

        let fontName = config.fontName ?? renderer.glyphAtlas.fontName
        let fontSize = CGFloat(config.fontSize ?? Double(renderer.glyphAtlas.fontSize))

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
        applyAppearanceSettingsToVisibleViews()
        integratedView?.setNeedsDisplay(integratedView?.bounds ?? .zero)
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
        switchToSplit(shortcutContext.displayedControllers + [newController])
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
            sourceView.clearSelection()
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
            return
        }

        do {
            if let result = try clipboardFileStore.importFromPasteboard(pasteboard) {
                pastedImageRegistry.register(createdFiles: result.createdFiles)
                controller.sendInput(result.textToPaste)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
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
        controller.onTitleChange = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateWindowTitle()
                self?.requestSessionPersist()
            }
        }
        controller.onStateChange = { [weak self] in
            DispatchQueue.main.async {
                self?.requestSessionPersist()
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
        let presentedMode: PersistedSessionState.PresentedMode
        let splitIDs: [UUID]
        switch viewMode {
        case .integrated:
            presentedMode = .integrated
            splitIDs = []
        case .focused:
            presentedMode = .focused
            splitIDs = []
        case .split(let controllers):
            presentedMode = .split
            splitIDs = controllers.map(\.id)
        }
        let state = PersistedSessionState(
            windowFrame: PersistedWindowFrame(frame: window.frame),
            focusedTerminalID: focusedController?.id,
            presentedMode: presentedMode,
            splitTerminalIDs: splitIDs,
            workspaceNames: workspaceNames,
            terminals: manager.terminals.map(\.sessionSnapshot)
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
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration())
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
        // Switching to another app should not tear down visible render resources.
        // Doing so forces glyph atlas / buffer reconstruction on the first frame
        // after reactivation, which can expose transient corruption before the
        // next demand-driven redraw settles. We still release on hide/minimize
        // and under memory pressure.
    }

    @objc func applicationDidBecomeActive(_ notification: Notification) {
        refreshMetricsMonitoringState()
        restoreVisibleRenderingResourcesIfNeeded()
    }

    @objc func applicationDidHide(_ notification: Notification) {
        stopMetricsMonitor()
        releaseInactiveRenderingResourcesNow()
    }

    @objc func applicationDidUnhide(_ notification: Notification) {
        refreshMetricsMonitoringState()
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
                    if glassView.superview !== rootView {
                        rootView?.addSubview(glassView, positioned: .below, relativeTo: hostedContentView)
                    } else {
                        rootView?.addSubview(glassView, positioned: .below, relativeTo: hostedContentView)
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
        metricsMonitor?.stop()
        clipboardCleanupService?.stop()
        manager?.stopAll(preserveScrollback: config.sessionScrollBufferPersistence)
        try? sessionStore.markCleanShutdown()
        singleInstanceLock.release()
    }
}

import AppKit
import MetalKit

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

private final class PtermWindow: NSWindow {
    var onBackToIntegratedShortcut: (() -> Void)?
    private static let supportedModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isBackToIntegratedShortcut(event) {
            onBackToIntegratedShortcut?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
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

    /// The single application window
    private var window: NSWindow!

    private var config: PtermConfig = .default

    private var statusBarView: StatusBarView!
    private var windowBackgroundGlassView: NSView?
    private var windowRootContentView: NSView!
    private var windowHostedContentView: NSView!
    private var configWatchSource: DispatchSourceFileSystemObject?
    private var pendingConfigReload: DispatchWorkItem?
    private var backShortcutMonitor: Any?
    private var titlebarBackButton: NSButton?

    private var metricsMonitor: ProcessMetricsMonitor?
    /// Tracks last output time per terminal for active-output indicator.
    private var lastOutputTimes: [UUID: Date] = [:]
    private var outputIdleTimer: Timer?
    /// Suppresses active-output indicator briefly after resize.
    private var lastResizeTime: Date = .distantPast
    /// Tracks terminals that have been idle at least once (initial output burst is over).
    private var terminalsEverIdle: Set<UUID> = []
    private let clipboardFileStore = ClipboardFileStore()
    private var clipboardCleanupService: ClipboardCleanupService?
    private let sessionStore = SessionStore()
    private let singleInstanceLock = SingleInstanceLock()
    private let appNoteStore = AppNoteStore()
    private lazy var exportImportManager = PtermExportImportManager(noteStore: appNoteStore)

    private var cpuUsageByPID: [pid_t: Double] = [:]
    private var lastMemoryByPID: [pid_t: UInt64] = [:]
    private var lastAppMemoryBytes: UInt64 = 0

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
    }

    static func shouldUseTranslucentWindowMaterial(
        isIntegratedViewVisible: Bool,
        terminalBackgroundOpacity: Double
    ) -> Bool {
        isIntegratedViewVisible || terminalBackgroundOpacity < 0.999
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Ensure ~/.pterm/ directories exist
        PtermDirectories.ensureDirectories()
        config = PtermConfigStore.load()
        startConfigWatcher()

        // Initialize Metal renderer
        guard let renderer = MetalRenderer(
            scaleFactor: NSScreen.main?.backingScaleFactor ?? 2.0
        ) else {
            fatalError("Failed to initialize Metal. GPU rendering is required.")
        }
        self.renderer = renderer
        renderer.updateTerminalAppearance(config.terminalAppearance)

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

        // Create integrated view
        let iv = IntegratedView(frame: contentBounds, renderer: renderer, manager: manager)
        iv.autoresizingMask = [.width, .height]
        iv.shortcutConfiguration = config.shortcuts
        iv.onSelectTerminal = { [weak self] controller in
            self?.switchToFocused(controller)
        }
        iv.onAddWorkspace = { [weak self] in
            self?.promptCreateWorkspace()
        }
        iv.onAddTerminalToWorkspace = { [weak self] workspace in
            self?.addNewTerminal(workspaceName: workspace)
        }
        iv.onRemoveWorkspace = { [weak self] workspace in
            self?.removeWorkspace(named: workspace)
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
        integratedView = iv
        syncIntegratedWorkspaceNames()
        contentHostView().addSubview(iv)
        applyAppearanceSettingsToVisibleViews()
        setupScrollbarOverlay(for: iv)
        isWindowLayoutReady = true
        synchronizeWindowLayout(shouldPersistSession: false)

        // React to terminal list changes
        manager.onListChanged = { [weak self] in
            self?.handleTerminalListChanged()
        }

        if let restoredSession {
            restoreSession(restoredSession)
        } else if bootstrapConfiguredWorkspaces() {
            switchToIntegrated()
        } else {
            addNewTerminal()
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
            persistSession()
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
                                id: UUID = UUID()) -> TerminalController? {
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

        if manager.count == 0 && workspaceNames.isEmpty {
            NSApplication.shared.terminate(nil)
            return
        }

        // If the focused terminal was removed, switch back to integrated view
        switch viewMode {
        case .focused(let controller):
            if !manager.terminals.contains(where: { $0 === controller }) {
                switchToIntegrated()
            }
        case .split(let controllers):
            let remaining = controllers.filter { current in
                manager.terminals.contains(where: { $0 === current })
            }
            if remaining.count >= 2 {
                switchToSplit(remaining)
            } else if let first = remaining.first {
                switchToFocused(first)
            } else {
                switchToIntegrated()
            }
        case .integrated:
            break
        }

        updateWindowTitle()
        persistSession()
    }

    // MARK: - View Switching

    private func switchToFocused(_ controller: TerminalController) {
        applyRendererSettings(for: controller)

        // Remove integrated view
        integratedView?.removeFromSuperview()
        scrollbarOverlay?.removeFromSuperview()
        scrollbarOverlay = nil
        splitContainerView?.removeFromSuperview()
        splitContainerView = nil

        // Create focused terminal view wrapped in scroll view
        let sv = TerminalScrollView(frame: availableContentFrame(), renderer: renderer)
        sv.autoresizingMask = [.width, .height]
        sv.shortcutConfiguration = config.shortcuts
        sv.terminalView.terminalController = controller
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
        contentHostView().addSubview(sv)
        terminalScrollView = sv
        terminalView = sv.terminalView
        terminalView?.applyAppearanceSettings()
        focusedController = controller

        viewMode = .focused(controller)
        updateTitlebarBackButtonVisibility()
        refreshStatusBarMetrics()
        window.makeFirstResponder(sv.terminalView)
        sv.terminalView.syncScaleFactorIfNeeded()

        updateWindowTitle()
        persistSession()
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

        integratedView?.removeFromSuperview()
        scrollbarOverlay?.removeFromSuperview()
        scrollbarOverlay = nil
        terminalScrollView?.removeFromSuperview()
        terminalScrollView = nil
        terminalView = nil
        focusedController = nil
        hideSearchBar()

        let splitView = SplitTerminalContainerView(frame: availableContentFrame(),
                                                   renderer: renderer,
                                                   controllers: controllers)
        splitView.autoresizingMask = [.width, .height]
        splitView.shortcutConfiguration = config.shortcuts
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
        contentHostView().addSubview(splitView)
        splitContainerView = splitView
        splitContainerView?.applyAppearanceSettings()
        splitOriginControllers = nil
        viewMode = .split(controllers)
        updateTitlebarBackButtonVisibility()
        refreshStatusBarMetrics()
        if let activeController = splitView.activeController {
            applyRendererSettings(for: activeController)
        }
        if let first = splitView.subviews.first as? TerminalScrollView {
            window.makeFirstResponder(first.terminalView)
        }
        updateWindowTitle()
        persistSession()
    }

    private func switchToIntegrated() {
        // Remove focused terminal scroll view
        terminalScrollView?.removeFromSuperview()
        terminalScrollView = nil
        splitContainerView?.removeFromSuperview()
        splitContainerView = nil
        scrollbarOverlay?.removeFromSuperview()
        scrollbarOverlay = nil
        terminalView = nil
        focusedController = nil
        splitOriginControllers = nil
        hideSearchBar()

        // Show integrated view
        let iv: IntegratedView
        if let existing = integratedView {
            iv = existing
        } else {
            iv = IntegratedView(frame: availableContentFrame(),
                                renderer: renderer, manager: manager)
            iv.autoresizingMask = [.width, .height]
            iv.shortcutConfiguration = config.shortcuts
            iv.onSelectTerminal = { [weak self] controller in
                self?.switchToFocused(controller)
            }
            iv.onAddWorkspace = { [weak self] in
                self?.promptCreateWorkspace()
            }
            iv.onAddTerminalToWorkspace = { [weak self] workspace in
                self?.addNewTerminal(workspaceName: workspace)
            }
            iv.onRemoveWorkspace = { [weak self] workspace in
                self?.removeWorkspace(named: workspace)
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
            integratedView = iv
        }

        iv.frame = availableContentFrame()
        iv.clearSelection()
        syncIntegratedWorkspaceNames()
        contentHostView().addSubview(iv)
        setupScrollbarOverlay(for: iv)
        applyAppearanceSettingsToVisibleViews()
        iv.syncScaleFactorIfNeeded()
        viewMode = .integrated
        updateTitlebarBackButtonVisibility()
        refreshStatusBarMetrics()
        window.makeFirstResponder(iv)

        updateWindowTitle()
        persistSession()
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

    private func terminalPIDs(for controller: TerminalController) -> [pid_t] {
        var pids: [pid_t] = [controller.processID]
        if let fg = controller.foregroundProcessID, fg != controller.processID {
            pids.append(fg)
        }
        return pids
    }

    private func refreshStatusBarMetrics() {
        switch viewMode {
        case .integrated:
            statusBarView.updateMemoryUsage(bytes: lastAppMemoryBytes)
            let appCpu = cpuUsageByPID[getpid()] ?? 0
            statusBarView.updateCpuUsage(percent: appCpu)
        case .focused(let controller):
            let pids = terminalPIDs(for: controller)
            let cpu = pids.compactMap { cpuUsageByPID[$0] }.reduce(0, +)
            let processMem = lastMemoryByPID[controller.processID] ?? 0
            let mem = processMem + controller.scrollbackCapacity
            statusBarView.updateCpuUsage(percent: cpu)
            statusBarView.updateMemoryUsage(bytes: mem)
        case .split(let controllers):
            var totalCpu: Double = 0
            var totalMem: UInt64 = 0
            for c in controllers {
                let pids = terminalPIDs(for: c)
                totalCpu += pids.compactMap { cpuUsageByPID[$0] }.reduce(0, +)
                totalMem += (lastMemoryByPID[c.processID] ?? 0) + c.scrollbackCapacity
            }
            statusBarView.updateCpuUsage(percent: totalCpu)
            statusBarView.updateMemoryUsage(bytes: totalMem)
        }
    }

    private func startMetricsMonitor() {
        let monitor = ProcessMetricsMonitor(interval: 3.0)
        monitor.onUpdate = { [weak self] snapshot in
            guard let self else { return }
            self.cpuUsageByPID = snapshot.cpuUsageByPID
            self.lastMemoryByPID = snapshot.memoryByPID
            self.lastAppMemoryBytes = snapshot.appMemoryBytes
            self.manager.terminals.forEach { terminal in
                if let cwd = snapshot.currentDirectoryByPID[terminal.processID] {
                    terminal.updateCurrentDirectory(path: cwd)
                }
            }
            self.refreshStatusBarMetrics()
        }
        monitor.start { [weak self] in
            guard let self else { return [] }
            var pids: [pid_t] = [getpid()]
            for terminal in self.manager.terminals {
                pids.append(terminal.processID)
                if let foregroundPID = terminal.foregroundProcessID,
                   foregroundPID != terminal.processID {
                    pids.append(foregroundPID)
                }
            }
            return pids
        }
        metricsMonitor = monitor
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
        switch viewMode {
        case .focused, .split:
            shouldShow = true
        case .integrated:
            shouldShow = false
        }
        titlebarBackButton?.isHidden = !shouldShow
        statusBarView?.setBackButtonVisible(shouldShow)
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
        manager.updateConfiguration(config)
        setupMenu()
        terminalView?.shortcutConfiguration = config.shortcuts
        splitContainerView?.shortcutConfiguration = config.shortcuts
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
        switch viewMode {
        case .integrated:
            let count = manager.count
            window.title = "pterm — \(count) terminal(s)"

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

            window.title = parts.joined(separator: " — ")
        case .split(let controllers):
            window.title = "pterm — split (\(controllers.count))"
        }
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
              let newController = addNewTerminal(workspaceName: shortcutContext.workspaceName) else {
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
            controller.sendInput("\u{03}")
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
                self?.persistSession()
            }
        }
        controller.onStateChange = { [weak self] in
            DispatchQueue.main.async {
                self?.persistSession()
            }
        }
        controller.onOutputActivity = { [weak self, weak controller] in
            guard let self, let controller else { return }
            let now = Date()
            // Always track last output time (needed to detect when terminal becomes idle)
            self.lastOutputTimes[controller.id] = now
            self.ensureOutputIdleTimer()
            // Suppress indicator briefly after window resize (SIGWINCH)
            if now.timeIntervalSince(self.lastResizeTime) < 1.0 { return }
            // Only show indicator for terminals that have been idle at least once.
            // This prevents the initial shell startup output from triggering the indicator.
            guard self.terminalsEverIdle.contains(controller.id) else { return }
            _ = self.integratedView?.setTerminalOutputActive(controller.id, isActive: true)
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
                    self.lastOutputTimes.removeValue(forKey: id)
                    self.terminalsEverIdle.insert(id)
                }
            }
            if self.lastOutputTimes.isEmpty {
                timer.invalidate()
                self.outputIdleTimer = nil
            }
        }
    }

    private func persistSession() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.persistSession()
            }
            return
        }
        guard let window, let manager else { return }
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
        try? sessionStore.save(state)
        if !isRestoringSession {
            cleanupOrphanedScrollbackFiles(retaining: Set(state.terminals.map(\.id)))
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

        cleanupOrphanedScrollbackFiles(retaining: Set(state.terminals.map(\.id)))

        if state.terminals.isEmpty {
            if !workspaceNames.isEmpty {
                switchToIntegrated()
                return
            }
            _ = addNewTerminal()
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
                                      message: "This password protects the encryption key for notes.")
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

        var password = promptPassword(title: "Import Password",
                                      message: "Enter the password used during export.")
        guard let initialPassword = password else { return }
        password = initialPassword

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

        while let currentPassword = password {
            do {
                try exportImportManager.importArchive(from: url, password: currentPassword)
                relaunchApplication()
                return
            } catch PtermExportImportError.invalidKeyEnvelope {
                password = promptPassword(title: "Incorrect Password",
                                          message: "Please re-enter the import password.")
            } catch {
                NSAlert(error: error).runModal()
                return
            }
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
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
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
        guard searchBarView == nil,
              let terminalView = activeSearchTerminalView() else { return }

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

        window.contentView = rootView
        windowRootContentView = rootView
        windowHostedContentView = hostedContentView
    }

    private func contentHostView() -> NSView {
        windowHostedContentView ?? window.contentView!
    }

    private func normalizeHostedContentFrame() {
        guard let rootView = windowRootContentView else { return }
        windowHostedContentView.frame = rootView.bounds
        windowHostedContentView.autoresizingMask = [.width, .height]
    }

    @objc private func activateFromSecondaryInstance(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func focusTerminal(at index: Int) {
        guard index >= 0, index < manager.terminals.count else { return }
        switchToFocused(manager.terminals[index])
    }

    private func removeWorkspace(named workspace: String) {
        let normalized = normalizedWorkspaceName(workspace)
        let targets = manager.terminals.filter { $0.sessionSnapshot.workspaceName == normalized }
        for controller in targets {
            manager.removeTerminal(controller)
        }
        workspaceNames.removeAll { $0 == normalized }
        syncIntegratedWorkspaceNames()
        persistSession()
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
        persistSession()
    }

    private func moveTerminal(_ controller: TerminalController, toWorkspace workspace: String) {
        let normalized = normalizedWorkspaceName(workspace)
        controller.setWorkspaceName(normalized)
        ensureWorkspaceExists(named: normalized)
        persistSession()
    }

    private func reorderTerminal(_ controller: TerminalController, toWorkspace workspace: String, atIndex index: Int) {
        let normalized = normalizedWorkspaceName(workspace)
        controller.setWorkspaceName(normalized)
        ensureWorkspaceExists(named: normalized)
        manager.reorderTerminal(controller, toWorkspace: normalized, atIndex: index)
        persistSession()
    }

    private func reorderWorkspace(_ name: String, toIndex index: Int) {
        let normalized = normalizedWorkspaceName(name)
        guard let fromIndex = workspaceNames.firstIndex(of: normalized) else { return }
        workspaceNames.remove(at: fromIndex)
        let adjustedIndex = min(index > fromIndex ? index - 1 : index, workspaceNames.count)
        workspaceNames.insert(normalized, at: adjustedIndex)
        syncIntegratedWorkspaceNames()
        persistSession()
    }

    private func renameTerminalTitle(_ controller: TerminalController, title: String?) {
        controller.setCustomTitle(title)
        persistSession()
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
        persistSession()
    }

    private func setupScrollbarOverlay(for iv: IntegratedView) {
        scrollbarOverlay?.removeFromSuperview()
        let overlay = ScrollbarOverlayView(frame: iv.frame)
        overlay.autoresizingMask = [.width, .height]
        overlay.drawsBackground = false
        overlay.backgroundColor = .clear
        overlay.hasVerticalScroller = true
        overlay.hasHorizontalScroller = false
        overlay.autohidesScrollers = true
        // Flipped document view so scroll starts from the top
        let docView = ScrollDocumentView(frame: NSRect(x: 0, y: 0, width: iv.bounds.width, height: iv.bounds.height))
        overlay.documentView = docView
        overlay.contentView.postsBoundsChangedNotifications = true
        contentHostView().addSubview(overlay)
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
            persistSession()
            return
        }
    }

    private func cleanupOrphanedScrollbackFiles(retaining ids: Set<UUID>) {
        guard config.sessionScrollBufferPersistence else {
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
        terminalScrollView?.frame = availableContentFrame()
        splitContainerView?.frame = availableContentFrame()
        integratedView?.frame = availableContentFrame()
        let contentBounds = availableContentFrame()
        let cols = max(1, Int((contentBounds.width - pad) / renderer.glyphAtlas.cellWidth))
        let rows = max(1, Int((contentBounds.height - pad) / renderer.glyphAtlas.cellHeight))
        manager.updateFullSize(rows: rows, cols: cols)
        updateWindowTitle()
        if shouldPersistSession {
            persistSession()
        }
    }

    func windowDidMove(_ notification: Notification) {
        persistSession()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        syncVisibleRenderScaleFactors()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        syncVisibleRenderScaleFactors()
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        syncVisibleRenderScaleFactors()
    }

    private func syncVisibleRenderScaleFactors() {
        layoutTitlebarBackButton()
        integratedView?.syncScaleFactorIfNeeded()
        terminalView?.syncScaleFactorIfNeeded()
        splitContainerView?.syncScaleFactorIfNeeded()
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
        persistSession()
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

import AppKit
import MetalKit
import ObjectiveC

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
    private var configWatchSource: DispatchSourceFileSystemObject?
    private var pendingConfigReload: DispatchWorkItem?
    private var backShortcutMonitor: Any?
    private var titlebarBackButton: NSButton?

    private var metricsMonitor: ProcessMetricsMonitor?
    /// Tracks last output time per terminal for active-output indicator.
    private var lastOutputTimes: [UUID: Date] = [:]
    private var outputIdleTimer: Timer?
    /// Suppresses active-output indicator briefly after resize or terminal creation.
    private var lastResizeTime: Date = .distantPast
    private var terminalCreationTimes: [UUID: Date] = [:]
    private let clipboardFileStore = ClipboardFileStore()
    private var clipboardCleanupService: ClipboardCleanupService?
    private let sessionStore = SessionStore()
    private let singleInstanceLock = SingleInstanceLock()
    private let workspaceNoteStore = WorkspaceNoteStore()
    private lazy var exportImportManager = PtermExportImportManager(noteStore: workspaceNoteStore)

    private var cpuUsageByPID: [pid_t: Double] = [:]

    /// Metal renderer (shared by all views)
    private var renderer: MetalRenderer!

    /// Terminal manager (manages all terminal sessions)
    private var manager: TerminalManager!

    /// Integrated view (grid of terminal thumbnails)
    private var integratedView: IntegratedView?

    /// Focused terminal scroll view (wraps TerminalView with native scrollbar)
    private var terminalScrollView: TerminalScrollView?

    /// Focused terminal view (single terminal occupying the window)
    private var terminalView: TerminalView?
    private var searchBarView: SearchBarView?
    private var splitContainerView: SplitTerminalContainerView?

    /// Currently focused terminal controller (nil = integrated view mode)
    private var focusedController: TerminalController?

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

    private final class WorkspaceNoteAutosaveDelegate: NSObject, NSTextViewDelegate {
        let onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onChange(textView.string)
        }
    }

    private enum WorkspaceNaming {
        static let uncategorized = "Uncategorized"
    }

    private var viewMode: ViewMode = .integrated
    private var isTerminating = false
    private var isWindowLayoutReady = false
    private var workspaceNames: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            if try !singleInstanceLock.acquireOrActivateExisting() {
                NSApp.terminate(nil)
                return
            }
        } catch {
            fatalError("Failed to acquire single-instance lock: \(error)")
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(activateFromSecondaryInstance(_:)),
            name: SingleInstanceLock.activationNotification,
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
        installTitlebarBackButton()

        // Dark appearance — standard dark mode title bar with visible title text,
        // matching macOS Terminal.app behavior
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isOpaque = true

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
        window.contentView!.addSubview(statusBarView)

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
        iv.onEditWorkspaceNote = { [weak self] workspace in
            self?.editWorkspaceNote(for: workspace)
        }
        iv.onMultiSelect = { [weak self] controllers in
            self?.switchToSplit(controllers)
        }
        iv.cpuUsageProvider = { [weak self] pid in
            self?.cpuUsageByPID[pid]
        }
        integratedView = iv
        syncIntegratedWorkspaceNames()
        window.contentView!.addSubview(iv)
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
        startMetricsMonitor()
        let cleanupService = ClipboardCleanupService(fileStore: clipboardFileStore)
        cleanupService.start()
        clipboardCleanupService = cleanupService
        installBackShortcutMonitor()

        // Setup menu
        setupMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !isTerminating {
            let aliveCount = manager.terminals.filter { $0.isAlive }.count
            if aliveCount > 0 {
                let alert = NSAlert()
                alert.messageText = "ptermを終了しますか？"
                alert.informativeText = "動作中のターミナルが\(aliveCount)つあります。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "終了")
                alert.addButton(withTitle: "キャンセル")

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
            let alert = NSAlert()
            alert.messageText = "ターミナルの起動に失敗しました"
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
        window.contentView!.addSubview(sv)
        terminalScrollView = sv
        terminalView = sv.terminalView
        focusedController = controller

        viewMode = .focused(controller)
        updateTitlebarBackButtonVisibility()
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
        window.contentView!.addSubview(splitView)
        splitContainerView = splitView
        viewMode = .split(controllers)
        updateTitlebarBackButtonVisibility()
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
        terminalView = nil
        focusedController = nil
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
            iv.onEditWorkspaceNote = { [weak self] workspace in
                self?.editWorkspaceNote(for: workspace)
            }
            iv.onMultiSelect = { [weak self] controllers in
                self?.switchToSplit(controllers)
            }
            iv.cpuUsageProvider = { [weak self] pid in
                self?.cpuUsageByPID[pid]
            }
            integratedView = iv
        }

        iv.frame = availableContentFrame()
        syncIntegratedWorkspaceNames()
        window.contentView!.addSubview(iv)
        iv.syncScaleFactorIfNeeded()
        viewMode = .integrated
        updateTitlebarBackButtonVisibility()
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
            return
        }

        renderer.updateFont(name: targetFontName, size: targetFontSize)
        terminalView?.fontSizeDidChange()
        splitContainerView?.fontSizeDidChange()
        integratedView?.setNeedsDisplay(integratedView?.bounds ?? .zero)
        updateWindowTitle()
    }

    private func terminalPIDs(for controller: TerminalController) -> [pid_t] {
        var pids: [pid_t] = [controller.processID]
        if let fg = controller.foregroundProcessID, fg != controller.processID {
            pids.append(fg)
        }
        return pids
    }

    private func startMetricsMonitor() {
        let monitor = ProcessMetricsMonitor(interval: 3.0)
        monitor.onUpdate = { [weak self] snapshot in
            guard let self else { return }
            self.cpuUsageByPID = snapshot.cpuUsageByPID
            self.manager.terminals.forEach { terminal in
                if let cwd = snapshot.currentDirectoryByPID[terminal.processID] {
                    terminal.updateCurrentDirectory(path: cwd)
                }
            }

            // Update status bar metrics based on current view mode
            switch self.viewMode {
            case .integrated:
                // App-level metrics
                self.statusBarView.updateMemoryUsage(bytes: snapshot.appMemoryBytes)
                let appPID = getpid()
                let appCpu = snapshot.cpuUsageByPID[appPID] ?? 0
                self.statusBarView.updateCpuUsage(percent: appCpu)
            case .focused(let controller):
                let pids = self.terminalPIDs(for: controller)
                let cpu = pids.compactMap { snapshot.cpuUsageByPID[$0] }.reduce(0, +)
                let processMem = snapshot.memoryByPID[controller.processID] ?? 0
                let mem = processMem + controller.scrollbackCapacity
                self.statusBarView.updateCpuUsage(percent: cpu)
                self.statusBarView.updateMemoryUsage(bytes: mem)
            case .split(let controllers):
                var totalCpu: Double = 0
                var totalMem: UInt64 = 0
                for c in controllers {
                    let pids = self.terminalPIDs(for: c)
                    totalCpu += pids.compactMap { snapshot.cpuUsageByPID[$0] }.reduce(0, +)
                    totalMem += (snapshot.memoryByPID[c.processID] ?? 0) + c.scrollbackCapacity
                }
                self.statusBarView.updateCpuUsage(percent: totalCpu)
                self.statusBarView.updateMemoryUsage(bytes: totalMem)
            }
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
        let bounds = window.contentView!.bounds
        let searchInset = searchBarView == nil ? 0 : Layout.searchBarHeight
        return NSRect(
            x: bounds.origin.x,
            y: bounds.origin.y + Layout.statusBarHeight,
            width: bounds.width,
            height: max(0, bounds.height - Layout.statusBarHeight - searchInset)
        )
    }

    private func statusBarFrame() -> NSRect {
        let bounds = window.contentView!.bounds
        return NSRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: Layout.statusBarHeight)
    }

    private func searchBarFrame() -> NSRect {
        let bounds = window.contentView!.bounds
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
        appMenu.addItem(withTitle: "ptermについて",
                       action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                       keyEquivalent: "")
        appMenu.addItem(makeMenuItem(title: "設定を開く", shortcut: .openSettings))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "エクスポート", action: #selector(exportData(_:)),
                        keyEquivalent: "")
        appMenu.addItem(withTitle: "インポート", action: #selector(importData(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "クリップボードファイルを開く", action: #selector(openClipboardFilesFolder(_:)),
                        keyEquivalent: "")
        appMenu.addItem(withTitle: "クリップボードファイルを削除", action: #selector(clearClipboardFiles(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(makeMenuItem(title: "ptermを終了", shortcut: .quit))
        appMenuItem.submenu = appMenu

        // Edit menu (for standard key bindings)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(makeMenuItem(title: "コピー", shortcut: .copy))
        editMenu.addItem(makeMenuItem(title: "切り取り", shortcut: .cut))
        editMenu.addItem(makeMenuItem(title: "ペースト", shortcut: .paste))
        editMenu.addItem(makeMenuItem(title: "すべてを選択", shortcut: .selectAll))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(makeMenuItem(title: "取り消し", shortcut: .undo))
        editMenu.addItem(makeMenuItem(title: "検索...", shortcut: .find))
        editMenuItem.submenu = editMenu

        // View menu (font size control + view switching)
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "表示")

        viewMenu.addItem(makeMenuItem(title: "フォントを拡大", shortcut: .zoomIn))
        viewMenu.addItem(makeMenuItem(title: "フォントを縮小", shortcut: .zoomOut))
        viewMenu.addItem(makeMenuItem(title: "デフォルトサイズに戻す", shortcut: .zoomReset))

        viewMenu.addItem(NSMenuItem.separator())

        // Cmd+Escape: back to integrated view
        viewMenu.addItem(makeMenuItem(title: "統合ビューに戻る", shortcut: .backToIntegrated))

        viewMenuItem.submenu = viewMenu

        // Shell menu
        let shellMenuItem = NSMenuItem()
        mainMenu.addItem(shellMenuItem)
        let shellMenu = NSMenu(title: "シェル")
        shellMenu.addItem(makeMenuItem(title: "新規ターミナル", shortcut: .newTerminal))
        shellMenu.addItem(makeMenuItem(title: "現在のターミナルを閉じる", shortcut: .closeTerminal))
        shellMenuItem.submenu = shellMenu

        let workspaceMenuItem = NSMenuItem()
        mainMenu.addItem(workspaceMenuItem)
        let workspaceMenu = NSMenu(title: "ワークスペース")
        workspaceMenu.addItem(withTitle: "メモを編集", action: #selector(editWorkspaceNote(_:)),
                              keyEquivalent: "")
        workspaceMenuItem.submenu = workspaceMenu

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

        if manager.count == 0 {
            let fontName = config.fontName ?? renderer.glyphAtlas.fontName
            let fontSize = CGFloat(config.fontSize ?? Double(renderer.glyphAtlas.fontSize))
            renderer.updateFont(name: fontName, size: fontSize)
            terminalView?.fontSizeDidChange()
            splitContainerView?.fontSizeDidChange()
            integratedView?.setNeedsDisplay(integratedView?.bounds ?? .zero)
        }

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
            window.title = "pterm — \(count)個のターミナル"

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
        if case .focused(let controller) = viewMode {
            addNewTerminal(workspaceName: controller.sessionSnapshot.workspaceName)
        } else if case .split(let controllers) = viewMode,
                  let first = controllers.first {
            addNewTerminal(workspaceName: first.sessionSnapshot.workspaceName)
        }
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

        let alert = NSAlert()
        alert.messageText = "複数行のテキストを貼り付けますか？"
        alert.informativeText = "改行を含むテキストを貼り付けようとしています。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "貼り付け")
        alert.addButton(withTitle: "キャンセル")
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
        terminalCreationTimes[controller.id] = Date()
        controller.onOutputActivity = { [weak self, weak controller] in
            guard let self, let controller else { return }
            let now = Date()
            // Suppress briefly after window resize (SIGWINCH) or terminal creation
            if now.timeIntervalSince(self.lastResizeTime) < 1.0 { return }
            if let created = self.terminalCreationTimes[controller.id],
               now.timeIntervalSince(created) < 2.0 { return }
            self.lastOutputTimes[controller.id] = now
            self.integratedView?.activeOutputTerminals.insert(controller.id)
            self.ensureOutputIdleTimer()
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
            var changed = false
            for (id, lastTime) in self.lastOutputTimes {
                if now.timeIntervalSince(lastTime) >= idleThreshold {
                    if self.integratedView?.activeOutputTerminals.remove(id) != nil {
                        changed = true
                    }
                    self.lastOutputTimes.removeValue(forKey: id)
                }
            }
            if self.lastOutputTimes.isEmpty {
                timer.invalidate()
                self.outputIdleTimer = nil
            }
            if changed {
                self.integratedView?.setNeedsDisplay(self.integratedView?.bounds ?? .zero)
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
        cleanupOrphanedScrollbackFiles(retaining: Set(state.terminals.map(\.id)))
    }

    private func loadRestorableSession() -> PersistedSessionState? {
        do {
            switch try sessionStore.prepareRestoreDecision() {
            case .none:
                return nil
            case .restore(let session):
                return session
            case .requireUserConfirmation(let session):
                let alert = NSAlert()
                alert.messageText = "前回のセッションを復元しますか？"
                alert.informativeText = "前回の終了が正常ではありませんでした。復元すると再び問題が起きる可能性があります。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "復元")
                alert.addButton(withTitle: "復元しない")
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
        let password = promptPassword(title: "エクスポート用パスワード",
                                      message: "ワークスペースメモの暗号鍵を保護します。")
        guard let password else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportImportManager.defaultExportURL().lastPathComponent
        panel.directoryURL = exportImportManager.defaultExportURL().deletingLastPathComponent()
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportImportManager.exportArchive(to: url, password: password)
            showInfoAlert(title: "エクスポート完了", message: url.path)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func importData(_ sender: Any?) {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.zip]
        openPanel.canChooseDirectories = false
        guard openPanel.runModal() == .OK, let url = openPanel.url else { return }

        var password = promptPassword(title: "インポート用パスワード",
                                      message: "エクスポート時に設定したパスワードを入力してください。")
        guard let initialPassword = password else { return }
        password = initialPassword

        let preview: PtermExportImportManager.ImportPreview
        do {
            preview = try exportImportManager.inspectArchive(url)
        } catch {
            NSAlert(error: error).runModal()
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "インポートを実行しますか？"
        let included = preview.includedItems.joined(separator: ", ")
        let overwritten = preview.overwrittenItems.isEmpty
            ? "上書き対象なし"
            : "上書き: " + preview.overwrittenItems.joined(separator: ", ")
        confirm.informativeText = "内容: \(included)\n\(overwritten)"
        confirm.addButton(withTitle: "実行")
        confirm.addButton(withTitle: "キャンセル")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        while let currentPassword = password {
            do {
                try exportImportManager.importArchive(from: url, password: currentPassword)
                relaunchApplication()
                return
            } catch PtermExportImportError.invalidKeyEnvelope {
                password = promptPassword(title: "パスワードが正しくありません",
                                          message: "インポート用パスワードを再入力してください。")
            } catch {
                NSAlert(error: error).runModal()
                return
            }
        }
    }

    @objc func openSettings(_ sender: Any?) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: PtermDirectories.config.path) {
            try? AtomicFileWriter.write(Data("{}".utf8), to: PtermDirectories.config, permissions: 0o600)
        }
        NSWorkspace.shared.open(PtermDirectories.config)
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
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    @objc private func openClipboardFilesFolder(_ sender: Any?) {
        NSWorkspace.shared.open(PtermDirectories.files)
    }

    @objc private func clearClipboardFiles(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "クリップボード保存ファイルを削除しますか？"
        alert.informativeText = "\(PtermDirectories.files.path) 配下の保存ファイルを全て削除します。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try clipboardFileStore.deleteAllStoredFiles()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
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
            break
        }
    }

    @objc func editWorkspaceNote(_ sender: Any?) {
        let workspaceName: String
        switch viewMode {
        case .focused(let controller):
            workspaceName = controller.sessionSnapshot.workspaceName
        case .split(let controllers):
            workspaceName = controllers.first?.sessionSnapshot.workspaceName ?? "Uncategorized"
        case .integrated:
            workspaceName = "Uncategorized"
        }
        editWorkspaceNote(for: workspaceName)
    }

    private func editWorkspaceNote(for workspaceName: String) {
        let alert = NSAlert()
        alert.messageText = "\(workspaceName) のメモ"
        alert.informativeText = "編集内容は即時保存されます。"
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        let textView = NSTextView(frame: scrollView.bounds)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        if let existing = ((try? workspaceNoteStore.loadNote(for: workspaceName)) ?? nil) {
            textView.string = existing
        }
        let autosaveDelegate = WorkspaceNoteAutosaveDelegate { [workspaceNoteStore] text in
            try? workspaceNoteStore.saveNote(text, for: workspaceName)
        }
        textView.delegate = autosaveDelegate
        objc_setAssociatedObject(alert, Unmanaged.passUnretained(alert).toOpaque(), autosaveDelegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "閉じる")
        alert.runModal()
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
        window.contentView!.addSubview(bar)
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
        try? workspaceNoteStore.removeWorkspaceData(for: normalized)
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
        try? workspaceNoteStore.renameWorkspaceData(from: source, to: target)
        persistSession()
    }

    private func moveTerminal(_ controller: TerminalController, toWorkspace workspace: String) {
        let normalized = normalizedWorkspaceName(workspace)
        controller.setWorkspaceName(normalized)
        ensureWorkspaceExists(named: normalized)
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
        let alert = NSAlert()
        alert.messageText = "ワークスペースを追加"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = ""
        alert.accessoryView = field
        alert.addButton(withTitle: "追加")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let normalized = normalizedWorkspaceName(field.stringValue)
        guard normalized != WorkspaceNaming.uncategorized else { return }
        ensureWorkspaceExists(named: normalized)
        persistSession()
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
        layoutTitlebarBackButton()
        integratedView?.syncScaleFactorIfNeeded()
        terminalView?.syncScaleFactorIfNeeded()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        layoutTitlebarBackButton()
        integratedView?.syncScaleFactorIfNeeded()
        terminalView?.syncScaleFactorIfNeeded()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let aliveCount = manager.terminals.filter { $0.isAlive }.count
        if aliveCount > 0 {
            let alert = NSAlert()
            alert.messageText = "ptermを終了しますか？"
            alert.informativeText = "動作中のターミナルが\(aliveCount)つあります。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "終了")
            alert.addButton(withTitle: "キャンセル")

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

import AppKit
import MetalKit

/// Application delegate for pterm.
///
/// Manages the single application window, terminal lifecycle,
/// view switching between integrated view and focused view,
/// and top-level keyboard shortcuts.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The single application window
    private var window: NSWindow!

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

    /// Currently focused terminal controller (nil = integrated view mode)
    private var focusedController: TerminalController?

    /// View mode
    private enum ViewMode {
        case integrated
        case focused(TerminalController)
    }

    private var viewMode: ViewMode = .integrated

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure ~/.pterm/ directories exist
        PtermDirectories.ensureDirectories()

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
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "pterm"
        window.minSize = NSSize(width: 400, height: 300)
        window.delegate = self
        window.isRestorable = false // Disable macOS state restoration

        // Dark appearance — standard dark mode title bar with visible title text,
        // matching macOS Terminal.app behavior
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isOpaque = true

        // Create terminal manager with initial grid size
        let pad = renderer.gridPadding * 2
        let contentBounds = window.contentView!.bounds
        let cols = max(1, Int((contentBounds.width - pad) / renderer.glyphAtlas.cellWidth))
        let rows = max(1, Int((contentBounds.height - pad) / renderer.glyphAtlas.cellHeight))
        manager = TerminalManager(rows: rows, cols: cols)

        // Create integrated view
        let iv = IntegratedView(frame: contentBounds, renderer: renderer, manager: manager)
        iv.autoresizingMask = [.width, .height]
        iv.onSelectTerminal = { [weak self] controller in
            self?.switchToFocused(controller)
        }
        iv.onAddTerminal = { [weak self] in
            self?.addNewTerminal()
        }
        iv.onMultiSelect = { [weak self] controllers in
            // TODO: split view for multi-select
            // For now, focus the first selected terminal
            if let first = controllers.first {
                self?.switchToFocused(first)
            }
        }
        integratedView = iv
        window.contentView!.addSubview(iv)

        // React to terminal list changes
        manager.onListChanged = { [weak self] in
            self?.handleTerminalListChanged()
        }

        // Create the first terminal
        addNewTerminal()

        // Show window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(integratedView)

        // Setup menu
        setupMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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

        manager.stopAll()
        return .terminateNow
    }

    // MARK: - Terminal Management

    @discardableResult
    private func addNewTerminal() -> TerminalController? {
        do {
            let controller = try manager.addTerminal()

            controller.onTitleChange = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateWindowTitle()
                }
            }

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
        // If all terminals are gone, close the app
        if manager.count == 0 {
            NSApplication.shared.terminate(nil)
            return
        }

        // If the focused terminal was removed, switch back to integrated view
        if case .focused(let controller) = viewMode {
            if !manager.terminals.contains(where: { $0 === controller }) {
                switchToIntegrated()
            }
        }

        updateWindowTitle()
    }

    // MARK: - View Switching

    private func switchToFocused(_ controller: TerminalController) {
        // Remove integrated view
        integratedView?.removeFromSuperview()

        // Create focused terminal view wrapped in scroll view
        let sv = TerminalScrollView(frame: window.contentView!.bounds, renderer: renderer)
        sv.autoresizingMask = [.width, .height]
        sv.terminalView.terminalController = controller
        sv.terminalView.onBackToIntegrated = { [weak self] in
            self?.switchToIntegrated()
        }
        window.contentView!.addSubview(sv)
        terminalScrollView = sv
        terminalView = sv.terminalView
        focusedController = controller

        viewMode = .focused(controller)
        window.makeFirstResponder(sv.terminalView)

        updateWindowTitle()
    }

    private func switchToIntegrated() {
        // Remove focused terminal scroll view
        terminalScrollView?.removeFromSuperview()
        terminalScrollView = nil
        terminalView = nil
        focusedController = nil

        // Show integrated view
        let iv: IntegratedView
        if let existing = integratedView {
            iv = existing
        } else {
            iv = IntegratedView(frame: window.contentView!.bounds,
                                renderer: renderer, manager: manager)
            iv.autoresizingMask = [.width, .height]
            iv.onSelectTerminal = { [weak self] controller in
                self?.switchToFocused(controller)
            }
            iv.onAddTerminal = { [weak self] in
                self?.addNewTerminal()
            }
            iv.onMultiSelect = { [weak self] controllers in
                if let first = controllers.first {
                    self?.switchToFocused(first)
                }
            }
            integratedView = iv
        }

        iv.frame = window.contentView!.bounds
        window.contentView!.addSubview(iv)
        viewMode = .integrated
        window.makeFirstResponder(iv)

        updateWindowTitle()
    }

    // MARK: - Metal Shaders

    private func loadShaders() {
        // Try to load compiled metallib first
        let bundle = Bundle.main
        if let libraryURL = bundle.url(forResource: "default", withExtension: "metallib"),
           let library = try? renderer.device.makeLibrary(URL: libraryURL) {
            renderer.setupPipelines(library: library)
            return
        }

        // Fall back to compiling from source (development mode)
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float2 position;
            float2 texCoord;
            float4 fgColor;
            float4 bgColor;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
            float4 fgColor;
            float4 bgColor;
        };

        struct Uniforms {
            float2 viewportSize;
            float  cursorOpacity;
            float  time;
        };

        vertex VertexOut bg_vertex(
            uint vertexID [[vertex_id]],
            constant VertexIn *vertices [[buffer(0)]],
            constant Uniforms &uniforms [[buffer(1)]]
        ) {
            VertexOut out;
            VertexIn in = vertices[vertexID];
            float2 ndc = (in.position / uniforms.viewportSize) * 2.0 - 1.0;
            ndc.y = -ndc.y;
            out.position = float4(ndc, 0.0, 1.0);
            out.texCoord = in.texCoord;
            out.fgColor = in.fgColor;
            out.bgColor = in.bgColor;
            return out;
        }

        fragment float4 bg_fragment(VertexOut in [[stage_in]]) {
            return in.bgColor;
        }

        vertex VertexOut glyph_vertex(
            uint vertexID [[vertex_id]],
            constant VertexIn *vertices [[buffer(0)]],
            constant Uniforms &uniforms [[buffer(1)]]
        ) {
            VertexOut out;
            VertexIn in = vertices[vertexID];
            float2 ndc = (in.position / uniforms.viewportSize) * 2.0 - 1.0;
            ndc.y = -ndc.y;
            out.position = float4(ndc, 0.0, 1.0);
            out.texCoord = in.texCoord;
            out.fgColor = in.fgColor;
            out.bgColor = in.bgColor;
            return out;
        }

        fragment float4 glyph_fragment(
            VertexOut in [[stage_in]],
            texture2d<float> atlas [[texture(0)]],
            sampler atlasSampler [[sampler(0)]]
        ) {
            float4 texColor = atlas.sample(atlasSampler, in.texCoord);
            float coverage = texColor.r;
            return float4(in.fgColor.rgb, coverage * in.fgColor.a);
        }

        fragment float4 cursor_fragment(
            VertexOut in [[stage_in]],
            constant Uniforms &uniforms [[buffer(1)]]
        ) {
            float alpha = 0.5 + 0.5 * sin(uniforms.time * 2.5);
            alpha = 0.3 + alpha * 0.7;
            return float4(in.fgColor.rgb, alpha * uniforms.cursorOpacity);
        }

        fragment float4 overlay_fragment(VertexOut in [[stage_in]]) {
            return in.fgColor;
        }
        """

        do {
            let library = try renderer.device.makeLibrary(source: shaderSource, options: nil)
            renderer.setupPipelines(library: library)
        } catch {
            fatalError("Failed to compile Metal shaders: \(error)")
        }
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
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "ptermを終了",
                       action: #selector(NSApplication.terminate(_:)),
                       keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // Edit menu (for standard key bindings)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "コピー", action: #selector(copy(_:)),
                        keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(paste(_:)),
                        keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(selectAll(_:)),
                        keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "検索...", action: #selector(performFindPanelAction(_:)),
                        keyEquivalent: "f")
        editMenuItem.submenu = editMenu

        // View menu (font size control + view switching)
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "表示")

        let zoomInItem = NSMenuItem(title: "フォントを拡大",
                                    action: #selector(fontSizeIncrease(_:)),
                                    keyEquivalent: "+")
        viewMenu.addItem(zoomInItem)

        // Also bind Cmd+= (without Shift) for convenience
        let zoomInItem2 = NSMenuItem(title: "フォントを拡大",
                                     action: #selector(fontSizeIncrease(_:)),
                                     keyEquivalent: "=")
        zoomInItem2.isAlternate = true
        viewMenu.addItem(zoomInItem2)

        viewMenu.addItem(withTitle: "フォントを縮小",
                        action: #selector(fontSizeDecrease(_:)),
                        keyEquivalent: "-")
        viewMenu.addItem(withTitle: "デフォルトサイズに戻す",
                        action: #selector(fontSizeReset(_:)),
                        keyEquivalent: "0")

        viewMenu.addItem(NSMenuItem.separator())

        // Cmd+Escape: back to integrated view
        let backItem = NSMenuItem(title: "統合ビューに戻る",
                                   action: #selector(backToIntegratedView(_:)),
                                   keyEquivalent: "\u{1B}") // Escape
        backItem.keyEquivalentModifierMask = .command
        viewMenu.addItem(backItem)

        viewMenuItem.submenu = viewMenu

        // Shell menu
        let shellMenuItem = NSMenuItem()
        mainMenu.addItem(shellMenuItem)
        let shellMenu = NSMenu(title: "シェル")
        shellMenu.addItem(withTitle: "新規ターミナル", action: #selector(newTerminal(_:)),
                         keyEquivalent: "t")
        shellMenuItem.submenu = shellMenu

        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: - Font Size

    private func applyFontSize(_ newSize: CGFloat) {
        renderer.updateFontSize(newSize)
        terminalView?.fontSizeDidChange()
        updateWindowTitle()
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
        applyFontSize(MetalRenderer.defaultFontSize)
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

            let oscTitle = controller.title
            if !oscTitle.isEmpty && oscTitle != "~" {
                parts.append(oscTitle)
            }

            controller.withModel { model in
                parts.append("\(model.cols)×\(model.rows)")
            }

            window.title = parts.joined(separator: " — ")
        }
    }

    // MARK: - Actions

    @objc func newTerminal(_ sender: Any?) {
        addNewTerminal()
        // If in focused mode, switch to integrated to see the new terminal
        if case .focused = viewMode {
            switchToIntegrated()
        }
    }

    @objc func backToIntegratedView(_ sender: Any?) {
        if case .focused = viewMode {
            switchToIntegrated()
        }
    }

    @objc func copy(_ sender: Any?) {
        guard case .focused(let controller) = viewMode else { return }

        if let text = terminalView?.selectedText() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            terminalView?.clearSelection()
        } else {
            // No selection: send SIGINT (Ctrl+C)
            controller.sendInput("\u{03}")
        }
    }

    @objc func paste(_ sender: Any?) {
        guard case .focused(let controller) = viewMode else { return }

        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string) else { return }

        if controller.model.bracketedPasteMode {
            let sanitized = text.replacingOccurrences(of: "\u{1B}[201~", with: "")
            controller.sendInput("\u{1B}[200~")
            controller.sendInput(sanitized)
            controller.sendInput("\u{1B}[201~")
        } else {
            controller.sendInput(text)
        }
    }

    @objc func selectAll(_ sender: Any?) {
        terminalView?.selectAll()
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        // TODO: implement search
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        // Update full-size grid dimensions for all terminals
        let pad = renderer.gridPadding * 2
        let contentBounds = window.contentView!.bounds
        let cols = max(1, Int((contentBounds.width - pad) / renderer.glyphAtlas.cellWidth))
        let rows = max(1, Int((contentBounds.height - pad) / renderer.glyphAtlas.cellHeight))
        manager.updateFullSize(rows: rows, cols: cols)
        updateWindowTitle()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        terminalView?.syncScaleFactorIfNeeded()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        terminalView?.syncScaleFactorIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        manager?.stopAll()
    }
}

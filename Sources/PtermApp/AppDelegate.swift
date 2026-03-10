import AppKit
import MetalKit

/// Application delegate for pterm.
///
/// Manages the single application window, terminal lifecycle,
/// and top-level keyboard shortcuts.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The single application window
    private var window: NSWindow!

    /// Metal renderer
    private var renderer: MetalRenderer!

    /// Terminal view
    private var terminalView: TerminalView!

    /// Active terminal controller
    private var terminalController: TerminalController!

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

        // Dark appearance — standard dark mode title bar with visible title text,
        // matching macOS Terminal.app behavior
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isOpaque = true

        // Create terminal view
        terminalView = TerminalView(frame: window.contentView!.bounds,
                                     renderer: renderer)
        terminalView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(terminalView)

        // Create terminal controller (account for grid padding)
        let pad = renderer.gridPadding * 2
        let cols = max(1, Int((terminalView.bounds.width - pad) / renderer.glyphAtlas.cellWidth))
        let rows = max(1, Int((terminalView.bounds.height - pad) / renderer.glyphAtlas.cellHeight))
        terminalController = TerminalController(rows: rows, cols: cols)
        terminalView.terminalController = terminalController

        // Update window title to match macOS Terminal format
        updateWindowTitle()

        terminalController.onTitleChange = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateWindowTitle()
            }
        }

        // Handle terminal exit
        terminalController.onExit = { [weak self] in
            // For now, close the app when the single terminal exits
            NSApplication.shared.terminate(nil)
        }

        // Start the terminal
        do {
            try terminalController.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "ターミナルの起動に失敗しました"
            alert.informativeText = "\(error)"
            alert.alertStyle = .critical
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }

        // Show window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminalView)

        // Setup menu
        setupMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Confirm exit if terminals are running
        if terminalController?.isAlive == true {
            let alert = NSAlert()
            alert.messageText = "ptermを終了しますか？"
            alert.informativeText = "動作中のターミナルが1つあります。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "終了")
            alert.addButton(withTitle: "キャンセル")

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                return .terminateCancel
            }
        }

        terminalController?.stop()
        return .terminateNow
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

        // View menu (font size control)
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
        terminalView.fontSizeDidChange()
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

    /// Update the window title to match macOS Terminal format:
    /// `<shell/process> — <directory> — <cols>×<rows>`
    private func updateWindowTitle() {
        guard let controller = terminalController else { return }

        var parts: [String] = []

        // Shell/process name
        let shellName = ProcessInfo.processInfo.environment["SHELL"]
            .flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "zsh"
        parts.append(shellName)

        // Title from OSC (typically the current directory or user-set title)
        let oscTitle = controller.title
        if !oscTitle.isEmpty && oscTitle != "~" {
            parts.append(oscTitle)
        }

        // Dimensions
        controller.withModel { model in
            parts.append("\(model.cols)×\(model.rows)")
        }

        window.title = parts.joined(separator: " — ")
    }

    // MARK: - Actions

    @objc func newTerminal(_ sender: Any?) {
        // TODO: implement multi-terminal in Phase 4
    }

    @objc func copy(_ sender: Any?) {
        if let text = terminalView.selectedText() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            terminalView.clearSelection()
        } else {
            // No selection: send SIGINT (Ctrl+C)
            terminalController.sendInput("\u{03}")
        }
    }

    @objc func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string) else { return }

        if terminalController.model.bracketedPasteMode {
            // Sanitize: strip the bracketed paste end sequence from pasted content
            // to prevent premature termination and command injection
            let sanitized = text.replacingOccurrences(of: "\u{1B}[201~", with: "")
            terminalController.sendInput("\u{1B}[200~")
            terminalController.sendInput(sanitized)
            terminalController.sendInput("\u{1B}[201~")
        } else {
            terminalController.sendInput(text)
        }
    }

    @objc func selectAll(_ sender: Any?) {
        terminalView.selectAll()
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        // TODO: implement search
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        // Terminal view handles resize via autoresizing mask.
        // Update title to reflect new dimensions.
        updateWindowTitle()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        // Trigger scale factor sync when window moves between displays
        terminalView?.syncScaleFactorIfNeeded()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        // Also handle backing property changes at the window level
        terminalView?.syncScaleFactorIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        terminalController?.stop()
    }
}

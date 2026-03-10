import AppKit
import MetalKit

/// NSView subclass that hosts a Metal layer for terminal rendering.
///
/// Handles keyboard input, mouse events, and delegates rendering
/// to the MetalRenderer.
final class TerminalView: MTKView {
    /// Terminal controller for this view
    var terminalController: TerminalController? {
        didSet { setupController() }
    }

    /// Metal renderer
    var renderer: MetalRenderer?

    /// Keyboard handler
    private var keyboardHandler: KeyboardHandler?

    // MARK: - Initialization

    init(frame: NSRect, renderer: MetalRenderer) {
        self.renderer = renderer

        super.init(frame: frame, device: renderer.device)

        self.delegate = self
        self.preferredFramesPerSecond = 60
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.isPaused = false
        self.enableSetNeedsDisplay = false

        // Accept keyboard input
        self.becomeFirstResponder()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Setup

    private func setupController() {
        guard let controller = terminalController else { return }

        keyboardHandler = KeyboardHandler(controller: controller)

        controller.onNeedsDisplay = { [weak self] in
            self?.setNeedsDisplay(self?.bounds ?? .zero)
        }
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        // Check for Cmd+key shortcuts first
        if event.modifierFlags.contains(.command) {
            // Let the responder chain handle Cmd+key shortcuts
            super.keyDown(with: event)
            return
        }

        keyboardHandler?.handleKeyDown(event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        // Handle modifier key changes if needed
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        // Make sure we're first responder for keyboard input
        window?.makeFirstResponder(self)
    }

    override func scrollWheel(with event: NSEvent) {
        // TODO: handle scroll for scrollback
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTerminalSize()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateTerminalSize()
    }

    private func updateTerminalSize() {
        guard let renderer = renderer,
              let controller = terminalController else { return }

        let cellW = renderer.glyphAtlas.cellWidth
        let cellH = renderer.glyphAtlas.cellHeight

        guard cellW > 0, cellH > 0 else { return }

        let cols = max(1, Int(bounds.width / cellW))
        let rows = max(1, Int(bounds.height / cellH))

        controller.resize(rows: rows, cols: cols)
    }

    /// Called when font size changes. Recalculates terminal grid dimensions.
    func fontSizeDidChange() {
        updateTerminalSize()
    }
}

// MARK: - MTKViewDelegate

extension TerminalView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        updateTerminalSize()
    }

    func draw(in view: MTKView) {
        guard let renderer = renderer,
              let controller = terminalController else { return }

        controller.withModel { model in
            renderer.render(model: model, in: view)
        }
    }
}

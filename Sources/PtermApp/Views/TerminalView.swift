import AppKit
import MetalKit

/// NSView subclass that hosts a Metal layer for terminal rendering.
///
/// Handles keyboard input, mouse events (text selection), scroll wheel
/// for scrollback navigation, and delegates rendering to the MetalRenderer.
final class TerminalView: MTKView {
    /// Terminal controller for this view
    var terminalController: TerminalController? {
        didSet { setupController() }
    }

    /// Metal renderer
    var renderer: MetalRenderer?

    /// Keyboard handler
    private var keyboardHandler: KeyboardHandler?

    /// Current text selection (nil = no selection)
    private(set) var selection: TerminalSelection?

    /// Click count tracker for double/triple click detection
    private var clickCount: Int = 0
    private var lastClickTime: TimeInterval = 0
    private var lastClickPosition: GridPosition?
    private static let multiClickInterval: TimeInterval = 0.3

    /// Accumulated scroll delta for smooth (trackpad) scrolling.
    /// We accumulate fractional lines until a full line is reached.
    private var scrollAccumulator: CGFloat = 0

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

        self.becomeFirstResponder()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Multi-Display Support

    /// Detect backing scale factor changes (moving between Retina/non-Retina displays).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncScaleFactor()
    }

    /// Also sync when the view moves to a new window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncScaleFactor()
    }

    /// Public entry point for NSWindowDelegate to trigger scale sync.
    func syncScaleFactorIfNeeded() {
        syncScaleFactor()
    }

    /// Synchronize the glyph atlas scale factor with the current display.
    private func syncScaleFactor() {
        guard let renderer = renderer else { return }
        let newScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if newScale != renderer.glyphAtlas.scaleFactor {
            renderer.glyphAtlas.updateScaleFactor(newScale)
            updateTerminalSize()
        }
    }

    // MARK: - Setup

    private func setupController() {
        guard let controller = terminalController else { return }

        keyboardHandler = KeyboardHandler(controller: controller)

        controller.onNeedsDisplay = { [weak self] in
            self?.setNeedsDisplay(self?.bounds ?? .zero)
        }
    }

    // MARK: - Grid Position from Mouse

    /// Convert a mouse event location (in view coordinates) to a grid position.
    private func gridPosition(from event: NSEvent) -> GridPosition? {
        guard let renderer = renderer else { return nil }

        let cellW = renderer.glyphAtlas.cellWidth
        let cellH = renderer.glyphAtlas.cellHeight
        guard cellW > 0, cellH > 0 else { return nil }

        let pad = renderer.gridPadding
        let locationInView = convert(event.locationInWindow, from: nil)
        // Flip Y: NSView origin is bottom-left, terminal origin is top-left
        let flippedY = bounds.height - locationInView.y

        let col = max(0, Int((locationInView.x - pad) / cellW))
        let row = max(0, Int((flippedY - pad) / cellH))

        return GridPosition(row: row, col: col)
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        // Any key press scrolls to bottom and clears selection
        terminalController?.scrollToBottom()
        clearSelection()

        keyboardHandler?.handleKeyDown(event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        // Handle modifier key changes if needed
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        guard let pos = gridPosition(from: event) else { return }

        let now = event.timestamp

        // Detect multi-click (double/triple)
        if let lastPos = lastClickPosition,
           lastPos == pos,
           now - lastClickTime < Self.multiClickInterval {
            clickCount += 1
        } else {
            clickCount = 1
        }
        lastClickTime = now
        lastClickPosition = pos

        if clickCount == 2 {
            // Double-click: word selection
            guard let controller = terminalController else { return }
            controller.withModel { model in
                selection = TerminalSelection.wordSelection(at: pos, in: model.grid)
            }
            return
        }

        if clickCount >= 3 {
            // Triple-click: line selection
            guard let controller = terminalController else { return }
            controller.withModel { model in
                selection = TerminalSelection.lineSelection(row: pos.row, cols: model.cols)
            }
            clickCount = 3 // cap
            return
        }

        // Single click
        if event.modifierFlags.contains(.shift), var sel = selection {
            // Shift+click: extend selection
            sel.active = pos
            selection = sel
        } else {
            // Start new selection
            let mode: SelectionMode = event.modifierFlags.contains(.option) ? .rectangular : .normal
            selection = TerminalSelection(anchor: pos, active: pos, mode: mode)
            selection?.isDragging = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var sel = selection, sel.isDragging else { return }
        guard let pos = gridPosition(from: event) else { return }

        sel.active = pos
        selection = sel
    }

    override func mouseUp(with event: NSEvent) {
        guard var sel = selection else { return }

        if sel.isDragging {
            if let pos = gridPosition(from: event) {
                sel.active = pos
            }
            sel.isDragging = false

            // If the selection is empty (click without drag), clear it
            if sel.isEmpty {
                selection = nil
            } else {
                selection = sel
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller = terminalController,
              let renderer = renderer else { return }

        let cellH = renderer.glyphAtlas.cellHeight
        guard cellH > 0 else { return }

        if event.hasPreciseScrollingDeltas {
            // Trackpad: smooth scrolling with pixel-level deltas.
            // Positive deltaY = scroll up (view older content).
            scrollAccumulator += event.scrollingDeltaY

            let lines = Int(scrollAccumulator / cellH)
            if lines != 0 {
                scrollAccumulator -= CGFloat(lines) * cellH
                if lines > 0 {
                    controller.scrollUp(lines: lines)
                } else {
                    controller.scrollDown(lines: -lines)
                }
            }
        } else {
            // Mouse wheel: discrete steps. Each notch scrolls 3 lines.
            let lines = 3
            if event.scrollingDeltaY > 0 {
                controller.scrollUp(lines: lines)
            } else if event.scrollingDeltaY < 0 {
                controller.scrollDown(lines: lines)
            }
        }
    }

    // MARK: - Selection API

    /// Clear the current selection.
    func clearSelection() {
        selection = nil
    }

    /// Select all text in the terminal.
    func selectAll() {
        guard let controller = terminalController else { return }
        controller.withModel { model in
            selection = TerminalSelection(
                anchor: GridPosition(row: 0, col: 0),
                active: GridPosition(row: model.rows - 1, col: model.cols - 1),
                mode: .normal
            )
        }
    }

    /// Get the selected text, or nil if no selection.
    func selectedText() -> String? {
        guard let sel = selection, !sel.isEmpty else { return nil }
        guard let controller = terminalController else { return nil }
        return controller.withModel { model in
            sel.extractText(from: model.grid)
        }
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

        let pad = renderer.gridPadding * 2  // padding on both sides
        let cols = max(1, Int((bounds.width - pad) / cellW))
        let rows = max(1, Int((bounds.height - pad) / cellH))

        controller.resize(rows: rows, cols: cols)

        // Clear selection on resize (grid coordinates change)
        clearSelection()
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

        controller.withViewport { model, scrollback, scrollOffset in
            renderer.render(model: model, scrollback: scrollback,
                          scrollOffset: scrollOffset, selection: selection, in: view)
        }
    }
}

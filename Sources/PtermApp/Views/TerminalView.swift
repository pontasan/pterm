import AppKit
import MetalKit

/// NSView subclass that hosts a Metal layer for terminal rendering.
///
/// Handles keyboard input, mouse events (text selection), scroll wheel
/// for scrollback navigation, and delegates rendering to the MetalRenderer.
/// Wrapped inside a TerminalScrollView for native macOS scrollbar behavior.
final class TerminalView: MTKView {
    /// Terminal controller for this view
    var terminalController: TerminalController? {
        didSet { setupController() }
    }

    /// Metal renderer
    var renderer: MetalRenderer?

    /// Keyboard handler
    private var keyboardHandler: KeyboardHandler?

    /// Callback when user requests to go back to integrated view (Cmd+Escape)
    var onBackToIntegrated: (() -> Void)?

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
        // Cmd+Escape: back to integrated view
        if event.modifierFlags.contains(.command) && event.keyCode == 53 {
            onBackToIntegrated?()
            return
        }

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
        // When inside a TerminalScrollView, forward to NSScrollView
        // so it handles scrolling natively (shows overlay scroller, momentum, etc.).
        // The scrollViewDidScroll notification translates clip position → scrollOffset.
        if enclosingScrollView is TerminalScrollView {
            super.scrollWheel(with: event)
            return
        }

        // Direct handling when not inside a scroll view (standalone mode)
        guard let controller = terminalController,
              let renderer = renderer else { return }

        let cellH = renderer.glyphAtlas.cellHeight
        guard cellH > 0 else { return }

        if event.hasPreciseScrollingDeltas {
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

        // Keep the native scroller in sync every frame
        (enclosingScrollView as? TerminalScrollView)?.syncScroller()
    }
}

// MARK: - TerminalScrollView

/// NSScrollView wrapper that provides native macOS scrollbar behavior
/// for the terminal's virtual scrollback.
///
/// The scroll view doesn't actually scroll the MTKView — instead it
/// syncs the native NSScroller position with TerminalController's
/// scrollOffset, giving the user standard macOS scrollbar interaction
/// (drag, hover-expand, click-in-track) over virtual content.
///
/// IMPORTANT: The terminal view's frame is managed explicitly (no
/// autoresizingMask) to prevent deadlocks. Changing the document view's
/// frame height (to reflect scrollback size) must not trigger a resize
/// cascade that tries to re-acquire the TerminalController lock.
final class TerminalScrollView: NSScrollView {
    /// The terminal view inside this scroll view.
    private(set) var terminalView: TerminalView!

    /// Guard against feedback loops during programmatic scroller updates.
    private var isSyncing = false

    init(frame: NSRect, renderer: MetalRenderer) {
        super.init(frame: frame)

        // Configure scroll view for overlay-style scrollbar
        self.hasVerticalScroller = true
        self.hasHorizontalScroller = false
        self.autohidesScrollers = true
        self.scrollerStyle = .overlay
        self.verticalScroller?.knobStyle = .light
        self.drawsBackground = false
        self.borderType = .noBorder
        self.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        // Create the flipped container (NSScrollView needs a flipped documentView)
        let container = FlippedDocumentView(frame: NSRect(origin: .zero, size: frame.size))
        self.documentView = container

        // Create the terminal MTKView.
        // NO autoresizingMask — we manage its frame explicitly to prevent
        // resize cascades when the document view height changes for scrollbar sync.
        terminalView = TerminalView(frame: NSRect(origin: .zero, size: frame.size),
                                     renderer: renderer)
        container.addSubview(terminalView)

        // Observe scroll events from the native scroller (for knob drag)
        self.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: self.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layout

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        // Update document view width to match, keep height as-is (managed by syncScroller)
        documentView?.frame.size.width = bounds.width
        pinTerminalViewToViewport()
    }

    /// Keep the terminal MTKView pinned to the visible area.
    /// The MTKView must always fill exactly the viewport — it renders
    /// the virtual scroll position, not a physical offset.
    private func pinTerminalViewToViewport() {
        terminalView.frame = NSRect(origin: contentView.bounds.origin,
                                     size: contentView.bounds.size)
    }

    // MARK: - Scroller Sync

    /// Sync the native scroller position with the terminal's virtual scroll state.
    /// Called every frame from TerminalView's draw(in:).
    ///
    /// Handles two directions:
    /// 1. Programmatic → UI: when scrollOffset changes (auto-scroll on output,
    ///    keyboard scrollToBottom), update the clip view position.
    /// 2. Document height: when scrollback grows, update document view height
    ///    so the scroller knob proportion reflects total content.
    ///
    /// CRITICAL: All reads from TerminalController happen first (under lock),
    /// then the lock is released BEFORE any UI mutation. This prevents deadlocks
    /// caused by layout cascades (docView resize → terminalView resize →
    /// updateTerminalSize → controller.resize → lock).
    func syncScroller() {
        guard let controller = terminalView.terminalController,
              let renderer = terminalView.renderer else { return }

        let cellH = renderer.glyphAtlas.cellHeight
        guard cellH > 0 else { return }

        // Step 1: Read scroll state under lock — NO UI mutation here.
        let (sbCount, viewRows, scrollOffset) = controller.withViewport { model, scrollback, offset in
            (scrollback.rowCount, model.rows, offset)
        }
        // Lock is now released.

        let totalRows = sbCount + viewRows
        let viewportHeight = self.bounds.height
        let documentHeight = max(viewportHeight, CGFloat(totalRows) * cellH)

        // Step 2: All UI mutations under isSyncing to block re-entrant notifications.
        isSyncing = true
        defer { isSyncing = false }

        let docView = self.documentView!
        if abs(docView.frame.height - documentHeight) > 1 {
            docView.frame = NSRect(x: 0, y: 0, width: self.bounds.width, height: documentHeight)
            self.reflectScrolledClipView(self.contentView)
        }

        // Map scrollOffset to clipView position.
        // scrollOffset 0 = bottom → clipView origin.y = maxY
        // scrollOffset == sbCount = top → clipView origin.y = 0
        let maxY = documentHeight - viewportHeight
        let targetY: CGFloat
        if sbCount > 0 {
            targetY = maxY * CGFloat(sbCount - scrollOffset) / CGFloat(sbCount)
        } else {
            targetY = maxY
        }

        // Use cellH tolerance to avoid fighting with NSScrollView's native
        // scroll positioning (which differs by sub-line pixel amounts).
        let currentY = self.contentView.bounds.origin.y
        if abs(currentY - targetY) > cellH {
            self.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            self.reflectScrolledClipView(self.contentView)
        }

        pinTerminalViewToViewport()
    }

    /// Handle user-initiated scrolling (scroll wheel, trackpad, knob drag).
    /// NSScrollView moves the clip view natively; we translate that position
    /// back to a scrollOffset for the terminal's virtual scrollback.
    @objc private func scrollViewDidScroll(_ notification: Notification) {
        guard !isSyncing else { return }
        guard let controller = terminalView.terminalController else { return }

        let viewportHeight = bounds.height
        let documentHeight = documentView?.frame.height ?? viewportHeight
        let maxY = documentHeight - viewportHeight
        guard maxY > 0 else { return }

        let currentY = contentView.bounds.origin.y
        let fraction = currentY / maxY  // 0 = top, 1 = bottom

        let sbCount = controller.withViewport { _, scrollback, _ in scrollback.rowCount }
        let newOffset = sbCount - Int(fraction * CGFloat(sbCount))
        controller.setScrollOffset(newOffset)

        pinTerminalViewToViewport()
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        return window?.makeFirstResponder(terminalView) ?? false
    }
}

/// Flipped document view so NSScrollView's origin is at the top.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

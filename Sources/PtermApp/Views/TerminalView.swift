import AppKit
import MetalKit
import QuartzCore

/// NSView subclass that hosts a Metal layer for terminal rendering.
///
/// Handles keyboard input, mouse events (text selection), scroll wheel
/// for scrollback navigation, and delegates rendering to the MetalRenderer.
/// Wrapped inside a TerminalScrollView for native macOS scrollbar behavior.
final class TerminalView: MTKView, NSTextInputClient {
    private struct MouseReportingState {
        let mode: TerminalModel.MouseReportingMode
        let protocolMode: TerminalModel.MouseProtocol
    }

    /// Terminal controller for this view
    var terminalController: TerminalController? {
        didSet { setupController() }
    }

    /// Metal renderer
    var renderer: MetalRenderer?
    var shortcutConfiguration: ShortcutConfiguration = .default
    private var selectAllActive = false

    /// Keyboard handler
    private var keyboardHandler: KeyboardHandler?

    /// Callback when user requests to go back to integrated view
    var onBackToIntegrated: (() -> Void)?
    var onBecameFirstResponder: (() -> Void)?

    /// Current text selection (nil = no selection)
    private(set) var selection: TerminalSelection? {
        didSet {
            setNeedsDisplay(bounds)
        }
    }

    /// Click count tracker for double/triple click detection
    private var clickCount: Int = 0
    private var lastClickTime: TimeInterval = 0
    private var lastClickPosition: GridPosition?
    private static let multiClickInterval: TimeInterval = 0.3

    /// Accumulated scroll delta for smooth (trackpad) scrolling.
    /// We accumulate fractional lines until a full line is reached.
    private var scrollAccumulator: CGFloat = 0
    private var searchMatches: [TerminalController.SearchMatch] = []
    private var currentSearchIndex: Int?
    private var selectionBeforeSearch: TerminalSelection?
    private var trackingArea: NSTrackingArea?
    private var pressedMouseButton: Int?
    private var windowObservers: [NSObjectProtocol] = []
    private let markedTextLayer = CATextLayer()
    private var markedTextStorage = NSMutableAttributedString()
    private var markedTextSelection = NSRange(location: NSNotFound, length: 0)
    private var pendingTextInputHandled = false

    /// URL hover state for Cmd+mouseover visual feedback
    private var hoveredLinkRange: (row: Int, startCol: Int, endCol: Int)?

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
        self.registerForDraggedTypes([.fileURL])
        self.wantsLayer = true
        configureMarkedTextLayer()

        _ = self.becomeFirstResponder()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecameFirstResponder?()
        }
        return accepted
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        for action in ShortcutAction.allCases {
            guard shortcutConfiguration.matches(action, event: event),
                  let selector = action.appDelegateSelector else {
                continue
            }
            if action == .backToIntegrated {
                onBackToIntegrated?()
                return true
            }
            return NSApp.sendAction(selector, to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }

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
        updateWindowObservers()
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
        updateMarkedTextOverlay()
    }

    // MARK: - Setup

    private func setupController() {
        guard let controller = terminalController else { return }

        keyboardHandler = KeyboardHandler(controller: controller)

        controller.onNeedsDisplay = { [weak self] in
            self?.setNeedsDisplay(self?.bounds ?? .zero)
            self?.updateMarkedTextOverlay()
        }
        controller.notifyFocusChanged(window?.isKeyWindow == true)
    }

    deinit {
        removeWindowObservers()
    }

    private func updateWindowObservers() {
        removeWindowObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.terminalController?.notifyFocusChanged(true)
            },
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.terminalController?.notifyFocusChanged(false)
            }
        ]
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        windowObservers.removeAll(keepingCapacity: true)
    }

    private func configureMarkedTextLayer() {
        markedTextLayer.isHidden = true
        markedTextLayer.alignmentMode = .left
        markedTextLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.addSublayer(markedTextLayer)
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
        if shortcutConfiguration.matches(.backToIntegrated, event: event) {
            onBackToIntegrated?()
            return
        }
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.control) {
            terminalController?.scrollToBottom()
            clearSelection()
            keyboardHandler?.handleKeyDown(event: event)
            return
        }

        // Any key press scrolls to bottom and clears selection
        terminalController?.scrollToBottom()
        clearSelection()
        pendingTextInputHandled = false
        interpretKeyEvents([event])
        if !pendingTextInputHandled && !hasMarkedText() {
            keyboardHandler?.handleKeyDown(event: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        updateLinkHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if !sendMouseEventIfNeeded(event, phase: .moved) {
            updateLinkHover(with: event)
        }
    }

    private func updateLinkHover(with event: NSEvent) {
        let commandHeld = event.modifierFlags.contains(.command)
        guard commandHeld,
              let controller = terminalController,
              let position = gridPosition(from: event),
              let link = controller.detectedLink(at: position) else {
            if hoveredLinkRange != nil {
                hoveredLinkRange = nil
                NSCursor.arrow.set()
            }
            return
        }

        let newRange = (row: position.row, startCol: link.startCol, endCol: link.endCol)
        if hoveredLinkRange?.row != newRange.row ||
           hoveredLinkRange?.startCol != newRange.startCol ||
           hoveredLinkRange?.endCol != newRange.endCol {
            hoveredLinkRange = newRange
            NSCursor.pointingHand.set()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let controller = terminalController,
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
              ) as? [URL],
              !urls.isEmpty else {
            return false
        }

        let quotedPaths = urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        controller.sendInput(quotedPaths.joined(separator: " "))
        return true
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        if event.modifierFlags.contains(.command),
           handleDetectedLinkClick(event) {
            return
        }

        if sendMouseEventIfNeeded(event, phase: .down, buttonOverride: 0) {
            return
        }

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
            var newSelection = TerminalSelection(anchor: pos, active: pos, mode: mode)
            newSelection.isDragging = true
            selection = newSelection
        }
    }

    private func handleDetectedLinkClick(_ event: NSEvent) -> Bool {
        guard let controller = terminalController,
              let position = gridPosition(from: event),
              let detectedLink = controller.detectedLink(at: position) else {
            return false
        }

        hoveredLinkRange = nil
        NSCursor.arrow.set()

        let scheme = detectedLink.url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(detectedLink.url)
            return true
        }

        let alert = NSAlert()
        alert.messageText = "このURLを開きますか？"
        alert.informativeText = detectedLink.originalText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "開く")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return true
        }

        NSWorkspace.shared.open(detectedLink.url)
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if !sendMouseEventIfNeeded(event, phase: .down, buttonOverride: 2) {
            super.rightMouseDown(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if !sendMouseEventIfNeeded(event, phase: .down, buttonOverride: 1) {
            super.otherMouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if sendMouseEventIfNeeded(event, phase: .dragged) {
            return
        }
        guard var sel = selection, sel.isDragging else { return }
        autoScrollSelectionIfNeeded(for: event)
        guard let pos = clampedGridPosition(from: event) else { return }

        sel.active = pos
        selection = sel
    }

    override func rightMouseDragged(with event: NSEvent) {
        if !sendMouseEventIfNeeded(event, phase: .dragged) {
            super.rightMouseDragged(with: event)
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if !sendMouseEventIfNeeded(event, phase: .dragged) {
            super.otherMouseDragged(with: event)
        }
    }

    private func autoScrollSelectionIfNeeded(for event: NSEvent) {
        guard let controller = terminalController,
              let renderer = renderer else { return }

        let location = convert(event.locationInWindow, from: nil)
        let margin = renderer.glyphAtlas.cellHeight
        guard margin > 0 else { return }

        if location.y < 0 {
            let lines = max(1, Int(ceil(abs(location.y) / margin)))
            if controller.scrollDown(lines: lines) {
                (enclosingScrollView as? TerminalScrollView)?.syncScroller()
            }
        } else if location.y > bounds.height {
            let lines = max(1, Int(ceil((location.y - bounds.height) / margin)))
            if controller.scrollUp(lines: lines) {
                (enclosingScrollView as? TerminalScrollView)?.syncScroller()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedMouseButton = nil }
        if sendMouseEventIfNeeded(event, phase: .up) {
            return
        }
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

    override func rightMouseUp(with event: NSEvent) {
        defer { pressedMouseButton = nil }
        if !sendMouseEventIfNeeded(event, phase: .up) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        defer { pressedMouseButton = nil }
        if !sendMouseEventIfNeeded(event, phase: .up) {
            super.otherMouseUp(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if sendMouseEventIfNeeded(event, phase: .scroll) {
            return
        }
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

    private enum MousePhase {
        case down
        case up
        case dragged
        case moved
        case scroll
    }

    private func sendMouseEventIfNeeded(_ event: NSEvent,
                                        phase: MousePhase,
                                        buttonOverride: Int? = nil) -> Bool {
        guard !event.modifierFlags.contains(.option),
              let controller = terminalController,
              let position = clampedGridPosition(from: event),
              let state = controller.withModel({ model -> MouseReportingState? in
                  guard model.mouseReporting != .none else { return nil }
                  return MouseReportingState(mode: model.mouseReporting, protocolMode: model.mouseProtocol)
              }) else {
            return false
        }

        switch phase {
        case .down:
            pressedMouseButton = buttonOverride ?? mouseButtonCode(for: event)
            guard let button = pressedMouseButton else { return false }
            controller.sendInput(encodeMouse(button: button, position: position, phase: .down,
                                             protocolMode: state.protocolMode))
            return true
        case .up:
            guard state.mode != .x10 else { return true }
            controller.sendInput(encodeMouse(button: pressedMouseButton ?? mouseButtonCode(for: event) ?? 0,
                                             position: position, phase: .up,
                                             protocolMode: state.protocolMode))
            return true
        case .dragged:
            guard state.mode == .buttonEvent || state.mode == .anyEvent,
                  let button = pressedMouseButton ?? mouseButtonCode(for: event) else { return false }
            controller.sendInput(encodeMouse(button: button, position: position, phase: .dragged,
                                             protocolMode: state.protocolMode))
            return true
        case .moved:
            guard state.mode == .anyEvent else { return false }
            controller.sendInput(encodeMouse(button: pressedMouseButton ?? 0, position: position, phase: .moved,
                                             protocolMode: state.protocolMode))
            return true
        case .scroll:
            guard event.scrollingDeltaY != 0 else { return false }
            let button = event.scrollingDeltaY > 0 ? 64 : 65
            controller.sendInput(encodeMouse(button: button, position: position, phase: .scroll,
                                             protocolMode: state.protocolMode))
            return true
        }
    }

    private func clampedGridPosition(from event: NSEvent) -> GridPosition? {
        guard let controller = terminalController,
              let position = gridPosition(from: event) else { return nil }
        let size = controller.withModel { ($0.rows, $0.cols) }
        return GridPosition(
            row: min(max(position.row, 0), max(0, size.0 - 1)),
            col: min(max(position.col, 0), max(0, size.1 - 1))
        )
    }

    private func mouseButtonCode(for event: NSEvent) -> Int? {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return 0
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
            return 2
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            return 1
        default:
            return 0
        }
    }

    private func encodeMouse(button: Int,
                             position: GridPosition,
                             phase: MousePhase,
                             protocolMode: TerminalModel.MouseProtocol) -> String {
        let col = position.col + 1
        let row = position.row + 1
        let baseCode: Int
        switch phase {
        case .up:
            baseCode = 3
        case .dragged, .moved:
            baseCode = button | 32
        case .down, .scroll:
            baseCode = button
        }

        switch protocolMode {
        case .sgr:
            let suffix = phase == .up ? "m" : "M"
            return "\u{1B}[<\(baseCode);\(col);\(row)\(suffix)"
        case .x10:
            let bytes: [UInt8] = [
                0x1B, 0x5B, 0x4D,
                UInt8(min(255, 32 + baseCode)),
                UInt8(min(255, 33 + col)),
                UInt8(min(255, 33 + row))
            ]
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    // MARK: - Selection API

    /// Clear the current selection.
    func clearSelection() {
        selectAllActive = false
        selection = nil
    }

    func beginSearch() {
        if selectionBeforeSearch == nil {
            selectionBeforeSearch = selection
        }
    }

    func updateSearch(query: String) -> (current: Int?, total: Int) {
        guard let controller = terminalController else {
            searchMatches = []
            currentSearchIndex = nil
            selection = nil
            return (nil, 0)
        }
        if query.isEmpty {
            searchMatches = []
            currentSearchIndex = nil
            selection = selectionBeforeSearch
            return (nil, 0)
        }

        searchMatches = controller.findMatches(for: query)
        if searchMatches.isEmpty {
            currentSearchIndex = nil
            selection = nil
            return (nil, 0)
        }

        currentSearchIndex = 0
        selection = controller.revealSearchMatch(searchMatches[0])
        return (1, searchMatches.count)
    }

    func navigateSearch(forward: Bool) -> (current: Int?, total: Int) {
        guard let controller = terminalController, !searchMatches.isEmpty else {
            return (nil, 0)
        }
        let nextIndex: Int
        if let currentSearchIndex {
            let delta = forward ? 1 : -1
            nextIndex = (currentSearchIndex + delta + searchMatches.count) % searchMatches.count
        } else {
            nextIndex = 0
        }
        currentSearchIndex = nextIndex
        selection = controller.revealSearchMatch(searchMatches[nextIndex])
        return (nextIndex + 1, searchMatches.count)
    }

    func endSearch() {
        searchMatches = []
        currentSearchIndex = nil
        selection = selectionBeforeSearch
        selectionBeforeSearch = nil
    }

    /// Select all text in the terminal.
    func selectAll() {
        guard let controller = terminalController else { return }
        selectAllActive = true
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
        guard let controller = terminalController else { return nil }
        if selectAllActive {
            return controller.allText()
        }
        guard let sel = selection, !sel.isEmpty else { return nil }
        return controller.selectedText(for: sel)
    }

    func cutMarkedText() -> String? {
        guard hasMarkedText() else { return nil }
        let text = markedTextStorage.string
        unmarkText()
        pendingTextInputHandled = true
        return text
    }

    @discardableResult
    func undoMarkedText() -> Bool {
        guard hasMarkedText() else { return false }
        unmarkText()
        pendingTextInputHandled = true
        return true
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTerminalSize()
        updateMarkedTextOverlay()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateTerminalSize()
        updateMarkedTextOverlay()
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

        let currentSize = controller.withModel { model in
            (rows: model.rows, cols: model.cols)
        }
        guard currentSize.rows != rows || currentSize.cols != cols else {
            return
        }

        controller.resize(rows: rows, cols: cols)

        // Clear selection on resize (grid coordinates change)
        clearSelection()
    }

    /// Called when font size changes. Recalculates terminal grid dimensions.
    func fontSizeDidChange() {
        updateTerminalSize()
        updateMarkedTextOverlay()
    }

    /// Update only the IME overlay without triggering a terminal resize.
    func updateMarkedTextOverlayPublic() {
        updateMarkedTextOverlay()
    }

    private func currentCursorRect() -> NSRect {
        guard let controller = terminalController,
              let renderer = renderer else {
            return .zero
        }
        let cursor = controller.withModel { $0.cursor }
        return NSRect(
            x: renderer.gridPadding + CGFloat(cursor.col) * renderer.glyphAtlas.cellWidth,
            y: bounds.height - renderer.gridPadding - CGFloat(cursor.row + 1) * renderer.glyphAtlas.cellHeight,
            width: renderer.glyphAtlas.cellWidth,
            height: renderer.glyphAtlas.cellHeight
        )
    }

    private func updateMarkedTextOverlay() {
        guard !markedTextStorage.string.isEmpty,
              let renderer = renderer else {
            markedTextLayer.isHidden = true
            return
        }

        let font = NSFont(name: renderer.glyphAtlas.fontName, size: renderer.glyphAtlas.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: renderer.glyphAtlas.fontSize, weight: .regular)
        let attributed = NSAttributedString(
            string: markedTextStorage.string,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        let cursorRect = currentCursorRect()
        markedTextLayer.string = attributed
        markedTextLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let size = attributed.size()
        markedTextLayer.frame = NSRect(
            x: cursorRect.minX,
            y: cursorRect.minY + max(0, (cursorRect.height - size.height) / 2),
            width: max(size.width, 1),
            height: max(size.height, cursorRect.height)
        )
        markedTextLayer.isHidden = false
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

        let highlight: MetalRenderer.SearchHighlight? = searchMatches.isEmpty ? nil :
            MetalRenderer.SearchHighlight(matches: searchMatches, currentIndex: currentSearchIndex)
        let linkUL: MetalRenderer.LinkUnderline? = hoveredLinkRange.map {
            MetalRenderer.LinkUnderline(row: $0.row, startCol: $0.startCol, endCol: $0.endCol)
        }

        controller.withViewport { model, scrollback, scrollOffset in
            renderer.render(model: model, scrollback: scrollback,
                          scrollOffset: scrollOffset, selection: selection,
                          searchHighlight: highlight, linkUnderline: linkUL, in: view)
        }

        // Keep the native scroller in sync every frame
        (enclosingScrollView as? TerminalScrollView)?.syncScroller()
    }
}

// MARK: - NSTextInputClient

extension TerminalView {
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let controller = terminalController else { return }
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else if let plain = string as? String {
            text = plain
        } else {
            text = String(describing: string)
        }
        guard !text.isEmpty else { return }
        pendingTextInputHandled = true
        markedTextStorage = NSMutableAttributedString()
        markedTextSelection = NSRange(location: NSNotFound, length: 0)
        markedTextLayer.isHidden = true
        controller.sendInput(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let attributed: NSAttributedString
        if let value = string as? NSAttributedString {
            attributed = value
        } else if let plain = string as? String {
            attributed = NSAttributedString(string: plain)
        } else {
            attributed = NSAttributedString(string: String(describing: string))
        }
        pendingTextInputHandled = true
        markedTextStorage = NSMutableAttributedString(attributedString: attributed)
        markedTextSelection = selectedRange
        updateMarkedTextOverlay()
    }

    func unmarkText() {
        markedTextStorage = NSMutableAttributedString()
        markedTextSelection = NSRange(location: NSNotFound, length: 0)
        markedTextLayer.isHidden = true
        updateMarkedTextOverlay()
    }

    func selectedRange() -> NSRange {
        markedTextSelection.location == NSNotFound ? NSRange(location: 0, length: 0) : markedTextSelection
    }

    func markedRange() -> NSRange {
        markedTextStorage.length == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedTextStorage.length)
    }

    func hasMarkedText() -> Bool {
        markedTextStorage.length > 0
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard hasMarkedText() else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        let location = min(max(0, range.location), markedTextStorage.length)
        let length = min(max(0, range.length), markedTextStorage.length - location)
        let actual = NSRange(location: location, length: length)
        actualRange?.pointee = actual
        return markedTextStorage.attributedSubstring(from: actual)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.font, .foregroundColor, .underlineStyle]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = currentCursorRect()
        actualRange?.pointee = range
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    override func doCommand(by selector: Selector) {
        pendingTextInputHandled = keyboardHandler?.handleCommand(selector: selector) ?? false
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
    private enum Layout {
        static let backButtonInset: CGFloat = 10
        static let backButtonSize = NSSize(width: 30, height: 24)
    }

    /// The terminal view inside this scroll view.
    private(set) var terminalView: TerminalView!
    private let backButton = NSButton(title: "▦", target: nil, action: nil)
    var shortcutConfiguration: ShortcutConfiguration = .default {
        didSet {
            terminalView.shortcutConfiguration = shortcutConfiguration
        }
    }

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
        terminalView.shortcutConfiguration = shortcutConfiguration
        container.addSubview(terminalView)

        backButton.bezelStyle = .texturedRounded
        backButton.isBordered = true
        backButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        backButton.contentTintColor = .white
        backButton.target = self
        backButton.action = #selector(backButtonPressed(_:))
        backButton.isHidden = true
        addSubview(backButton)

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
        layoutBackButton()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if shortcutConfiguration.matches(.backToIntegrated, event: event) {
            terminalView.onBackToIntegrated?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Keep the terminal MTKView pinned to the visible area.
    /// The MTKView must always fill exactly the viewport — it renders
    /// the virtual scroll position, not a physical offset.
    private func pinTerminalViewToViewport() {
        let targetFrame = NSRect(origin: contentView.bounds.origin,
                                 size: contentView.bounds.size)
        if terminalView.frame != targetFrame {
            terminalView.frame = targetFrame
        }
    }

    private func layoutBackButton() {
        backButton.frame = NSRect(
            x: Layout.backButtonInset,
            y: Layout.backButtonInset,
            width: Layout.backButtonSize.width,
            height: Layout.backButtonSize.height
        )
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

    @objc private func backButtonPressed(_ sender: Any?) {
        terminalView.onBackToIntegrated?()
    }
}

/// Flipped document view so NSScrollView's origin is at the top.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let terminalView = subviews.first(where: { $0 is TerminalView }),
           terminalView.frame.contains(point) {
            return terminalView
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let terminalView = subviews.first(where: { $0 is TerminalView }) as? TerminalView else {
            super.mouseDown(with: event)
            return
        }
        terminalView.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let terminalView = subviews.first(where: { $0 is TerminalView }) as? TerminalView else {
            super.mouseDragged(with: event)
            return
        }
        terminalView.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let terminalView = subviews.first(where: { $0 is TerminalView }) as? TerminalView else {
            super.mouseUp(with: event)
            return
        }
        terminalView.mouseUp(with: event)
    }
}

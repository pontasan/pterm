import AppKit
import MetalKit

/// Displays all terminal sessions as a grid of live thumbnails.
///
/// Each thumbnail renders its terminal content at full PTY grid resolution,
/// scaled down by the GPU to fit the thumbnail cell. Clicking a thumbnail
/// switches to the focused (occupied) view. Shift+click enables multi-select
/// for split display.
final class IntegratedView: MTKView, NSDraggingSource {
    private struct WorkspaceSection {
        let name: String
        let terminals: [TerminalController]
    }

    private struct ThumbnailLayout {
        let controller: TerminalController
        let thumbnail: NSRect
        let title: NSRect
        let close: NSRect
        let workspace: String
    }

    private struct WorkspaceLayout {
        let name: String
        let frame: NSRect
        let headerFrame: NSRect
        let noteFrame: NSRect
        let addFrame: NSRect
        let closeFrame: NSRect
        let terminals: [ThumbnailLayout]
    }

    /// Terminal manager
    private let manager: TerminalManager

    /// Metal renderer
    private let renderer: MetalRenderer

    /// Callback: user clicked a terminal thumbnail (single select).
    var onSelectTerminal: ((TerminalController) -> Void)?

    /// Callback: user wants to add a new terminal.
    var onAddTerminal: (() -> Void)?
    var onAddWorkspace: (() -> Void)?
    var onAddTerminalToWorkspace: ((String) -> Void)?
    var onRemoveWorkspace: ((String) -> Void)?
    var onRenameWorkspace: ((String, String) -> Void)?
    var onMoveTerminalToWorkspace: ((TerminalController, String) -> Void)?
    var onRenameTerminalTitle: ((TerminalController, String?) -> Void)?
    var onEditWorkspaceNote: ((String) -> Void)?

    /// Set of currently selected terminals (for multi-select with Shift)
    private(set) var selectedTerminals: Set<UUID> = []

    /// Callback: user shift-clicked multiple terminals for split view.
    var onMultiSelect: (([TerminalController]) -> Void)?

    /// CPU usage provider for status labels.
    var cpuUsageProvider: ((pid_t) -> Double?)?
    var controlReturnedTerminals: Set<UUID> = []
    var shortcutConfiguration: ShortcutConfiguration = .default
    var explicitWorkspaceNames: [String] = [] {
        didSet { setNeedsDisplay(bounds) }
    }

    /// Tracking area for mouse hover (close buttons, etc.)
    private var trackingArea: NSTrackingArea?

    /// Index of the thumbnail currently under the mouse (for hover effects)
    private var hoveredIndex: Int?

    /// Index of the thumbnail whose close button is hovered
    private var hoveredCloseIndex: Int?

    /// Stored frame for the add button (updated each draw)
    private var addButtonFrame: NSRect = .zero
    private var addWorkspaceButtonFrame: NSRect = .zero
    private var cachedWorkspaceLayouts: [WorkspaceLayout] = []
    private var mouseDownPoint: NSPoint?
    private var mouseDownTerminal: TerminalController?

    /// Layout constants
    private struct Layout {
        static let thumbnailPadding: CGFloat = 12
        static let workspacePadding: CGFloat = 16
        static let workspaceHeaderHeight: CGFloat = 28
        static let titleBarHeight: CGFloat = 24
        static let closeButtonSize: CGFloat = 16
        static let addButtonSize: CGFloat = 40
        static let cornerRadius: CGFloat = 6
        static let titleFontSize: CGFloat = 11
        static let borderWidth: CGFloat = 1.5
        static let workspaceBorderWidth: CGFloat = 1.0
    }

    // MARK: - Initialization

    init(frame: NSRect, renderer: MetalRenderer, manager: TerminalManager) {
        self.renderer = renderer
        self.manager = manager

        super.init(frame: frame, device: renderer.device)

        self.delegate = self
        self.preferredFramesPerSecond = 30 // Lower FPS for thumbnails
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.registerForDraggedTypes([.string])

        updateTrackingArea()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Multi-Display Support

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncScaleFactor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncScaleFactor()
    }

    func syncScaleFactorIfNeeded() {
        syncScaleFactor()
    }

    private func syncScaleFactor() {
        let newScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if newScale != renderer.glyphAtlas.scaleFactor {
            renderer.glyphAtlas.updateScaleFactor(newScale)
        }
        // Ensure drawable matches Retina pixel dimensions
        let expectedSize = CGSize(width: bounds.width * newScale, height: bounds.height * newScale)
        if abs(drawableSize.width - expectedSize.width) > 1 || abs(drawableSize.height - expectedSize.height) > 1 {
            drawableSize = expectedSize
        }
    }

    // MARK: - Tracking Area

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    // MARK: - Layout

    private func workspaceSections() -> [WorkspaceSection] {
        let grouped = Dictionary(grouping: manager.terminals) { controller in
            let name = controller.sessionSnapshot.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Uncategorized" : name
        }
        let explicit = explicitWorkspaceNames.map {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Uncategorized" : trimmed
        }

        var orderedNames: [String] = []
        var seen = Set<String>()

        for name in explicit where !seen.contains(name) {
            seen.insert(name)
            orderedNames.append(name)
        }

        for controller in manager.terminals {
            let trimmed = controller.sessionSnapshot.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "Uncategorized" : trimmed
            if !seen.contains(name) {
                seen.insert(name)
                orderedNames.append(name)
            }
        }

        return orderedNames.map { WorkspaceSection(name: $0, terminals: grouped[$0] ?? []) }
    }

    private func workspaceLayouts() -> [WorkspaceLayout] {
        let sections = workspaceSections()
        guard !sections.isEmpty else { return [] }

        let outerPad = Layout.workspacePadding
        let innerPad = Layout.thumbnailPadding
        let availableWidth = bounds.width - outerPad * 2
        let totalHeight = max(bounds.height - outerPad * 2 - CGFloat(sections.count - 1) * outerPad, 0)
        let baseSectionHeight = sections.isEmpty ? 0 : totalHeight / CGFloat(sections.count)
        var layouts: [WorkspaceLayout] = []
        var currentY = outerPad

        for section in sections {
            let terminalCount = max(section.terminals.count, 1)
            let (gridCols, gridRows) = TerminalManager.gridLayout(for: terminalCount)
            let sectionHeight = max(baseSectionHeight, 180)
            let frame = NSRect(x: outerPad, y: currentY, width: availableWidth, height: sectionHeight)
            let headerFrame = NSRect(x: frame.minX + innerPad,
                                     y: frame.minY + innerPad / 2,
                                     width: frame.width - innerPad * 2,
                                     height: Layout.workspaceHeaderHeight)
            let addFrame = NSRect(x: headerFrame.maxX - Layout.closeButtonSize - 6,
                                  y: headerFrame.minY + (headerFrame.height - Layout.closeButtonSize) / 2,
                                  width: Layout.closeButtonSize,
                                  height: Layout.closeButtonSize)
            let closeFrame = NSRect(x: addFrame.minX - Layout.closeButtonSize - 6,
                                    y: addFrame.minY,
                                    width: Layout.closeButtonSize,
                                    height: Layout.closeButtonSize)
            let noteFrame = NSRect(x: closeFrame.minX - Layout.closeButtonSize - 6,
                                   y: addFrame.minY,
                                   width: Layout.closeButtonSize,
                                   height: Layout.closeButtonSize)

            let contentFrame = NSRect(x: frame.minX + innerPad,
                                      y: headerFrame.maxY + innerPad / 2,
                                      width: frame.width - innerPad * 2,
                                      height: max(0, frame.height - headerFrame.height - innerPad * 2))
            let cellW = contentFrame.width / CGFloat(max(gridCols, 1))
            let cellH = contentFrame.height / CGFloat(max(gridRows, 1))

            var thumbnailLayouts: [ThumbnailLayout] = []
            for (index, controller) in section.terminals.enumerated() {
                let gridCol = index % gridCols
                let gridRow = index / gridCols
                let cellX = contentFrame.minX + CGFloat(gridCol) * cellW
                let cellY = contentFrame.minY + CGFloat(gridRow) * cellH
                let previewFrames = centeredPreviewFrames(
                    for: controller,
                    cellFrame: NSRect(x: cellX, y: cellY, width: cellW, height: cellH),
                    innerPadding: innerPad
                )
                let titleFrame = previewFrames.title
                let thumbFrame = previewFrames.thumbnail
                let closeFrame = NSRect(
                    x: titleFrame.origin.x + 4,
                    y: titleFrame.origin.y + (Layout.titleBarHeight - Layout.closeButtonSize) / 2,
                    width: Layout.closeButtonSize,
                    height: Layout.closeButtonSize
                )
                thumbnailLayouts.append(ThumbnailLayout(
                    controller: controller,
                    thumbnail: thumbFrame,
                    title: titleFrame,
                    close: closeFrame,
                    workspace: section.name
                ))
            }

            layouts.append(WorkspaceLayout(name: section.name, frame: frame, headerFrame: headerFrame,
                                           noteFrame: noteFrame, addFrame: addFrame, closeFrame: closeFrame, terminals: thumbnailLayouts))
            currentY += sectionHeight + outerPad
        }

        return layouts
    }

    private func centeredPreviewFrames(
        for controller: TerminalController,
        cellFrame: NSRect,
        innerPadding: CGFloat
    ) -> (title: NSRect, thumbnail: NSRect) {
        let maxBoxWidth = max(0, cellFrame.width - innerPadding)
        let maxBoxHeight = max(0, cellFrame.height - innerPadding)
        let maxContentHeight = max(0, maxBoxHeight - Layout.titleBarHeight)
        let contentAspect = thumbnailAspectRatio(for: controller)

        var contentWidth = min(maxBoxWidth, maxContentHeight * contentAspect)
        var contentHeight = contentAspect > 0 ? contentWidth / contentAspect : 0
        if contentHeight > maxContentHeight {
            contentHeight = maxContentHeight
            contentWidth = contentHeight * contentAspect
        }

        let totalHeight = Layout.titleBarHeight + contentHeight
        let originX = cellFrame.minX + (cellFrame.width - contentWidth) / 2
        let originY = cellFrame.minY + (cellFrame.height - totalHeight) / 2

        let title = NSRect(x: originX, y: originY, width: contentWidth, height: Layout.titleBarHeight)
        let thumbnail = NSRect(x: originX, y: title.maxY, width: contentWidth, height: contentHeight)
        return (title, thumbnail)
    }

    private func thumbnailAspectRatio(for controller: TerminalController) -> CGFloat {
        let gridSize = controller.withModel { (rows: $0.rows, cols: $0.cols) }
        let cellWidth = max(renderer.glyphAtlas.cellWidth, 1)
        let cellHeight = max(renderer.glyphAtlas.cellHeight, 1)
        let contentWidth = CGFloat(max(gridSize.cols, 1)) * cellWidth
        let contentHeight = CGFloat(max(gridSize.rows, 1)) * cellHeight
        guard contentHeight > 0 else { return 1.6 }
        return max(0.8, min(3.0, contentWidth / contentHeight))
    }

    /// Return the index of the thumbnail at the given view-coordinates point.
    private func thumbnailIndex(at point: NSPoint) -> Int? {
        let flattened = cachedWorkspaceLayouts.flatMap(\.terminals)
        for (index, layout) in flattened.enumerated() {
            if layout.title.union(layout.thumbnail).contains(point) {
                return index
            }
        }
        return nil
    }

    /// Check if a point hits a close button.
    private func closeButtonIndex(at point: NSPoint) -> Int? {
        let flattened = cachedWorkspaceLayouts.flatMap(\.terminals)
        for (i, f) in flattened.enumerated() {
            // Slightly larger hit area for the close button
            let hitRect = f.close.insetBy(dx: -4, dy: -4)
            if hitRect.contains(point) {
                return i
            }
        }
        return nil
    }

    private func workspaceAddTarget(at point: NSPoint) -> String? {
        for layout in cachedWorkspaceLayouts where layout.addFrame.insetBy(dx: -4, dy: -4).contains(point) {
            return layout.name
        }
        return nil
    }

    private func workspaceNoteTarget(at point: NSPoint) -> String? {
        for layout in cachedWorkspaceLayouts where layout.noteFrame.insetBy(dx: -4, dy: -4).contains(point) {
            return layout.name
        }
        return nil
    }

    private func workspaceRemoveTarget(at point: NSPoint) -> String? {
        for layout in cachedWorkspaceLayouts where layout.closeFrame.insetBy(dx: -4, dy: -4).contains(point) {
            return layout.name
        }
        return nil
    }

    private func workspaceHeaderTarget(at point: NSPoint) -> String? {
        for layout in cachedWorkspaceLayouts where layout.headerFrame.contains(point) {
            return layout.name
        }
        return nil
    }

    private func terminalTitleTarget(at point: NSPoint) -> TerminalController? {
        let flattened = cachedWorkspaceLayouts.flatMap(\.terminals)
        for layout in flattened where layout.title.contains(point) && !layout.close.insetBy(dx: -4, dy: -4).contains(point) {
            return layout.controller
        }
        return nil
    }

    // MARK: - Flipped Coordinates

    override var isFlipped: Bool { true }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        mouseDownTerminal = nil

        // Check add button
        if addButtonFrame.contains(point) {
            onAddTerminal?()
            return
        }

        if addWorkspaceButtonFrame.contains(point) {
            onAddWorkspace?()
            return
        }

        if let workspace = workspaceAddTarget(at: point) {
            onAddTerminalToWorkspace?(workspace)
            return
        }

        if let workspace = workspaceNoteTarget(at: point) {
            onEditWorkspaceNote?(workspace)
            return
        }

        if let workspace = workspaceRemoveTarget(at: point) {
            onRemoveWorkspace?(workspace)
            return
        }

        if event.clickCount == 2,
           let workspace = workspaceHeaderTarget(at: point),
           workspaceAddTarget(at: point) == nil,
           workspaceRemoveTarget(at: point) == nil {
            promptRenameWorkspace(workspace)
            return
        }

        if event.clickCount == 2,
           let controller = terminalTitleTarget(at: point) {
            promptRenameTerminalTitle(controller)
            return
        }

        // Check close button first
        if let closeIdx = closeButtonIndex(at: point),
           closeIdx < manager.terminals.count {
            let controller = manager.terminals[closeIdx]
            manager.removeTerminal(controller)
            return
        }

        // Check thumbnail click
        guard let idx = thumbnailIndex(at: point),
              idx < manager.terminals.count else {
            return
        }

        let flattened = cachedWorkspaceLayouts.flatMap(\.terminals)
        guard idx < flattened.count else { return }
        let controller = flattened[idx].controller
        mouseDownTerminal = controller

        if event.modifierFlags.contains(.shift) {
            // Multi-select with Shift
            if selectedTerminals.contains(controller.id) {
                selectedTerminals.remove(controller.id)
            } else {
                selectedTerminals.insert(controller.id)
            }

            // If multiple terminals selected, trigger split view
            let selected = manager.terminals.filter { selectedTerminals.contains($0.id) }
            if selected.count >= 2 {
                onMultiSelect?(selected)
                selectedTerminals.removeAll()
            }
        } else {
            // Single click: focus this terminal
            selectedTerminals.removeAll()
            onSelectTerminal?(controller)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseDownPoint,
              let controller = mouseDownTerminal else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) > 6 else { return }

        let item = NSPasteboardItem()
        item.setString(controller.id.uuidString, forType: .string)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: NSSize(width: 140, height: 24))
        image.lockFocus()
        NSColor(calibratedWhite: 0.18, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 140, height: 24), xRadius: 6, yRadius: 6).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ]
        NSString(string: controller.title).draw(in: NSRect(x: 8, y: 4, width: 124, height: 16), withAttributes: attrs)
        image.unlockFocus()
        draggingItem.setDraggingFrame(NSRect(origin: point, size: image.size), contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
        mouseDownTerminal = nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredIndex = thumbnailIndex(at: point)
        hoveredCloseIndex = closeButtonIndex(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        hoveredCloseIndex = nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: .string) != nil else { return [] }
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: .string) != nil else { return [] }
        return .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let idString = sender.draggingPasteboard.string(forType: .string),
              let id = UUID(uuidString: idString) else {
            return false
        }
        let point = convert(sender.draggingLocation, from: nil)
        guard let workspace = workspaceHeaderTarget(at: point),
              let controller = manager.terminals.first(where: { $0.id == id }) else {
            return false
        }
        onMoveTerminalToWorkspace?(controller, workspace)
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    private func promptRenameWorkspace(_ workspace: String) {
        let alert = NSAlert()
        alert.messageText = "ワークスペース名を変更"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = workspace
        alert.accessoryView = field
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != workspace else { return }
        onRenameWorkspace?(workspace, newName)
    }

    private func promptRenameTerminalTitle(_ controller: TerminalController) {
        let alert = NSAlert()
        alert.messageText = "ターミナルタイトルを変更"
        alert.informativeText = "空欄にするとカレントディレクトリ名に戻ります。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = controller.customTitle ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onRenameTerminalTitle?(controller, value.isEmpty ? nil : value)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Cmd+T: new terminal (handled by menu, but also catch here)
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        for action in ShortcutAction.allCases {
            guard shortcutConfiguration.matches(action, event: event),
                  let selector = action.appDelegateSelector else {
                continue
            }
            return NSApp.sendAction(selector, to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - MTKViewDelegate

extension IntegratedView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Nothing to do — layout is computed each frame
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            return
        }

        let sf = Float(renderer.glyphAtlas.scaleFactor)
        let terminals = manager.terminals
        let count = terminals.count
        cachedWorkspaceLayouts = workspaceLayouts()

        renderPassDescriptor.colorAttachments[0].clearColor =
            MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor) else {
            return
        }

        let drawableSize = view.drawableSize
        let viewportSize = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))

        // Render each terminal thumbnail
        if count > 0 {
            let flattened = cachedWorkspaceLayouts.flatMap(\.terminals)

            for workspace in cachedWorkspaceLayouts {
                drawWorkspaceBackground(
                    encoder: encoder,
                    workspace: workspace,
                    scaleFactor: sf,
                    viewportSize: viewportSize
                )
            }

            for (i, frame) in flattened.enumerated() {
                let controller = frame.controller
                let fontSettings = controller.persistedFontSettings
                if renderer.glyphAtlas.fontName != fontSettings.name ||
                    abs(Double(renderer.glyphAtlas.fontSize) - fontSettings.size) > 0.001 {
                    renderer.updateFont(name: fontSettings.name, size: CGFloat(fontSettings.size))
                }

                // Draw thumbnail border/background
                let isHovered = hoveredIndex == i
                let isSelected = selectedTerminals.contains(controller.id)
                let isControlReturned = controlReturnedTerminals.contains(controller.id)

                drawThumbnailBackground(
                    encoder: encoder,
                    frame: frame.thumbnail,
                    titleFrame: frame.title,
                    isHovered: isHovered,
                    isSelected: isSelected,
                    isControlReturned: isControlReturned,
                    scaleFactor: sf,
                    viewportSize: viewportSize
                )

                // Draw terminal content scaled to thumbnail size
                controller.withViewport { model, scrollback, scrollOffset in
                    renderer.renderThumbnail(
                        model: model,
                        scrollback: scrollback,
                        scrollOffset: scrollOffset,
                        encoder: encoder,
                        viewportSize: viewportSize,
                        thumbnailRect: frame.thumbnail,
                        scaleFactor: sf
                    )
                }

                // Draw title text
                drawTitle(
                    encoder: encoder,
                    title: controller.title,
                    pid: controller.foregroundProcessID ?? controller.processID,
                    frame: frame.title,
                    scaleFactor: sf,
                    viewportSize: viewportSize
                )

                // Draw close button
                let isCloseHovered = hoveredCloseIndex == i
                drawCloseButton(
                    encoder: encoder,
                    frame: frame.close,
                    isHovered: isCloseHovered,
                    scaleFactor: sf,
                    viewportSize: viewportSize
                )
            }
        }

        // Draw "+" button for adding new terminal
        drawAddButton(encoder: encoder, scaleFactor: sf, viewportSize: viewportSize,
                      terminalCount: count)
        drawAddWorkspaceButton(encoder: encoder, scaleFactor: sf, viewportSize: viewportSize)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Drawing Helpers

    private func drawThumbnailBackground(
        encoder: MTLRenderCommandEncoder,
        frame: NSRect,
        titleFrame: NSRect,
        isHovered: Bool,
        isSelected: Bool,
        isControlReturned: Bool,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.overlayPipeline else { return }

        let fullFrame = titleFrame.union(frame)
        let x = Float(fullFrame.origin.x) * scaleFactor
        let y = Float(fullFrame.origin.y) * scaleFactor
        let w = Float(fullFrame.width) * scaleFactor
        let h = Float(fullFrame.height) * scaleFactor

        var vertices: [Float] = []

        // Title bar background (dark gray)
        let titleX = Float(titleFrame.origin.x) * scaleFactor
        let titleY = Float(titleFrame.origin.y) * scaleFactor
        let titleW = Float(titleFrame.width) * scaleFactor
        let titleH = Float(titleFrame.height) * scaleFactor
        renderer.addQuadPublic(
            to: &vertices, x: titleX, y: titleY, w: titleW, h: titleH,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (0.15, 0.15, 0.15, 1.0),
            bg: (0, 0, 0, 0)
        )

        // Terminal content background (solid black)
        let contentX = Float(frame.origin.x) * scaleFactor
        let contentY = Float(frame.origin.y) * scaleFactor
        let contentW = Float(frame.width) * scaleFactor
        let contentH = Float(frame.height) * scaleFactor
        renderer.addQuadPublic(
            to: &vertices, x: contentX, y: contentY, w: contentW, h: contentH,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (0.0, 0.0, 0.0, 1.0),
            bg: (0, 0, 0, 0)
        )

        // Border
        let borderAlpha: Float = isControlReturned ? 0.95 : (isSelected ? 0.9 : (isHovered ? 0.6 : 0.3))
        let borderColor: (Float, Float, Float)
        if isControlReturned {
            borderColor = (0.95, 0.72, 0.18)
        } else if isSelected {
            borderColor = (0.3, 0.6, 1.0)
        } else {
            borderColor = (0.4, 0.4, 0.4)
        }
        let bw: Float = Float(Layout.borderWidth) * scaleFactor
        // Top
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: w, h: bw,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (borderColor.0, borderColor.1, borderColor.2, borderAlpha),
                               bg: (0, 0, 0, 0))
        // Bottom
        renderer.addQuadPublic(to: &vertices, x: x, y: y + h - bw, w: w, h: bw,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (borderColor.0, borderColor.1, borderColor.2, borderAlpha),
                               bg: (0, 0, 0, 0))
        // Left
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: bw, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (borderColor.0, borderColor.1, borderColor.2, borderAlpha),
                               bg: (0, 0, 0, 0))
        // Right
        renderer.addQuadPublic(to: &vertices, x: x + w - bw, y: y, w: bw, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (borderColor.0, borderColor.1, borderColor.2, borderAlpha),
                               bg: (0, 0, 0, 0))

        drawVertices(vertices, encoder: encoder, pipeline: pipeline, viewportSize: viewportSize)
    }

    private func drawWorkspaceBackground(
        encoder: MTLRenderCommandEncoder,
        workspace: WorkspaceLayout,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.overlayPipeline else { return }

        let x = Float(workspace.frame.origin.x) * scaleFactor
        let y = Float(workspace.frame.origin.y) * scaleFactor
        let w = Float(workspace.frame.width) * scaleFactor
        let h = Float(workspace.frame.height) * scaleFactor
        let bw = Float(Layout.workspaceBorderWidth) * scaleFactor

        var vertices: [Float] = []
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: w, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.07, 0.07, 0.07, 0.65), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: w, h: bw,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.28, 0.28, 0.28, 0.7), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &vertices, x: x, y: y + h - bw, w: w, h: bw,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.28, 0.28, 0.28, 0.7), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: bw, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.28, 0.28, 0.28, 0.7), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &vertices, x: x + w - bw, y: y, w: bw, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.28, 0.28, 0.28, 0.7), bg: (0, 0, 0, 0))
        drawVertices(vertices, encoder: encoder, pipeline: pipeline, viewportSize: viewportSize)

        drawWorkspaceHeaderText(
            encoder: encoder,
            text: workspace.name,
            frame: workspace.headerFrame,
            scaleFactor: scaleFactor,
            viewportSize: viewportSize
        )
        drawWorkspaceAddButton(
            encoder: encoder,
            frame: workspace.addFrame,
            scaleFactor: scaleFactor,
            viewportSize: viewportSize
        )
        drawWorkspaceNoteButton(
            encoder: encoder,
            frame: workspace.noteFrame,
            scaleFactor: scaleFactor,
            viewportSize: viewportSize
        )
        drawWorkspaceCloseButton(
            encoder: encoder,
            frame: workspace.closeFrame,
            scaleFactor: scaleFactor,
            viewportSize: viewportSize
        )
    }

    private func drawWorkspaceHeaderText(
        encoder: MTLRenderCommandEncoder,
        text: String,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        drawRightAlignedTitleText(
            encoder: encoder,
            text: text,
            frame: NSRect(x: frame.minX - frame.width + 120, y: frame.minY, width: frame.width, height: frame.height),
            scaleFactor: scaleFactor,
            viewportSize: viewportSize,
            color: (0.9, 0.9, 0.9, 1.0),
            alignment: .left
        )
    }

    private func drawTitle(
        encoder: MTLRenderCommandEncoder,
        title: String,
        pid: pid_t,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.glyphPipeline,
              let atlas = renderer.glyphAtlas.texture else { return }

        var vertices: [Float] = []

        // Render title text character by character using the glyph atlas
        let titleChars = Array(title.unicodeScalars)
        let maxChars = Int(frame.width / renderer.glyphAtlas.cellWidth) - 2 // Leave room for close button
        let displayChars = min(titleChars.count, max(0, maxChars))

        // Title text starts after the close button area
        let textStartX = Float(frame.origin.x + Layout.closeButtonSize + 8) * scaleFactor
        let textY = Float(frame.origin.y + (Layout.titleBarHeight - renderer.glyphAtlas.cellHeight) / 2) * scaleFactor
        let cellW = Float(renderer.glyphAtlas.cellWidth) * scaleFactor
        // Scale factor for thumbnail text: render at a reasonable size
        let thumbGlyphScale: Float = 0.85

        for i in 0..<displayChars {
            let cp = titleChars[i].value
            guard cp > 0x20,
                  let glyph = renderer.glyphAtlas.glyphInfo(for: cp),
                  glyph.pixelWidth > 0 else {
                continue
            }

            let x = textStartX + Float(i) * cellW * thumbGlyphScale
            let glyphX = x + Float(glyph.bearingX) * scaleFactor * thumbGlyphScale
            let baselineScreenY = textY + Float(renderer.glyphAtlas.cellHeight) * scaleFactor * thumbGlyphScale - Float(renderer.glyphAtlas.baseline) * scaleFactor * thumbGlyphScale
            let glyphY = baselineScreenY - glyph.baselineOffset * thumbGlyphScale
            let glyphW = Float(glyph.pixelWidth) * thumbGlyphScale
            let glyphH = Float(glyph.pixelHeight) * thumbGlyphScale

            renderer.addQuadPublic(
                to: &vertices,
                x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                tx: glyph.textureX, ty: glyph.textureY,
                tw: glyph.textureW, th: glyph.textureH,
                fg: (0.8, 0.8, 0.8, 1),
                bg: (0, 0, 0, 0)
            )
        }

        if !vertices.isEmpty {
            encoder.setRenderPipelineState(pipeline)
            let buf = renderer.makeTemporaryBuffer(vertices: vertices)
            if let buf = buf {
                var uniforms = MetalRenderer.MetalUniforms(
                    viewportSize: viewportSize,
                    cursorOpacity: 0,
                    time: 0
                )
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalRenderer.MetalUniforms>.size, index: 1)
                encoder.setFragmentTexture(atlas, index: 0)
                encoder.setFragmentSamplerState(renderer.samplerState, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                      vertexCount: vertices.count / 12)
            }
        }

        if let usage = cpuUsageProvider?(pid),
           usage >= 0 {
            drawRightAlignedTitleText(
                encoder: encoder,
                text: String(format: "%.1f%%", usage),
                frame: frame,
                scaleFactor: scaleFactor,
                viewportSize: viewportSize
            )
        }
    }

    private func drawRightAlignedTitleText(
        encoder: MTLRenderCommandEncoder,
        text: String,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        color: (Float, Float, Float, Float) = (0.55, 0.55, 0.55, 1.0),
        alignment: NSTextAlignment = .right
    ) {
        guard let pipeline = renderer.glyphPipeline,
              let atlas = renderer.glyphAtlas.texture else { return }

        let chars = Array(text.unicodeScalars)
        var vertices: [Float] = []
        let thumbGlyphScale: Float = 0.8
        let cellW = Float(renderer.glyphAtlas.cellWidth) * scaleFactor * thumbGlyphScale
        let textWidth = Float(chars.count) * cellW
        let startX: Float
        if alignment == .left {
            startX = Float(frame.minX) * scaleFactor
        } else {
            startX = Float(frame.maxX) * scaleFactor - textWidth - 8 * scaleFactor
        }
        let textY = Float(frame.origin.y + (Layout.titleBarHeight - renderer.glyphAtlas.cellHeight) / 2) * scaleFactor

        for (index, scalar) in chars.enumerated() {
            let cp = scalar.value
            guard cp > 0x20,
                  let glyph = renderer.glyphAtlas.glyphInfo(for: cp),
                  glyph.pixelWidth > 0 else {
                continue
            }

            let x = startX + Float(index) * cellW
            let glyphX = x + Float(glyph.bearingX) * scaleFactor * thumbGlyphScale
            let baselineScreenY = textY + Float(renderer.glyphAtlas.cellHeight) * scaleFactor * thumbGlyphScale - Float(renderer.glyphAtlas.baseline) * scaleFactor * thumbGlyphScale
            let glyphY = baselineScreenY - glyph.baselineOffset * thumbGlyphScale
            let glyphW = Float(glyph.pixelWidth) * thumbGlyphScale
            let glyphH = Float(glyph.pixelHeight) * thumbGlyphScale

            renderer.addQuadPublic(
                to: &vertices,
                x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                tx: glyph.textureX, ty: glyph.textureY,
                tw: glyph.textureW, th: glyph.textureH,
                fg: color,
                bg: (0, 0, 0, 0)
            )
        }

        guard !vertices.isEmpty else { return }
        encoder.setRenderPipelineState(pipeline)
        if let buf = renderer.makeTemporaryBuffer(vertices: vertices) {
            var uniforms = MetalRenderer.MetalUniforms(viewportSize: viewportSize, cursorOpacity: 0, time: 0)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalRenderer.MetalUniforms>.size, index: 1)
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.setFragmentSamplerState(renderer.samplerState, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 12)
        }
    }

    private func drawWorkspaceAddButton(
        encoder: MTLRenderCommandEncoder,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.overlayPipeline else { return }
        var vertices: [Float] = []
        let x = Float(frame.origin.x) * scaleFactor
        let y = Float(frame.origin.y) * scaleFactor
        let size = Float(frame.width) * scaleFactor
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: size, h: size,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.22, 0.22, 0.22, 0.9), bg: (0, 0, 0, 0))
        let lineW: Float = 2.0 * scaleFactor
        let lineLen: Float = size * 0.5
        let cx = x + size / 2
        let cy = y + size / 2
        renderer.addQuadPublic(to: &vertices, x: cx - lineLen / 2, y: cy - lineW / 2,
                               w: lineLen, h: lineW, tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.85, 0.85, 0.85, 1.0), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &vertices, x: cx - lineW / 2, y: cy - lineLen / 2,
                               w: lineW, h: lineLen, tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.85, 0.85, 0.85, 1.0), bg: (0, 0, 0, 0))
        drawVertices(vertices, encoder: encoder, pipeline: pipeline, viewportSize: viewportSize)
    }

    private func drawWorkspaceNoteButton(
        encoder: MTLRenderCommandEncoder,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.overlayPipeline else { return }
        var vertices: [Float] = []
        let x = Float(frame.origin.x) * scaleFactor
        let y = Float(frame.origin.y) * scaleFactor
        let size = Float(frame.width) * scaleFactor
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: size, h: size,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.18, 0.22, 0.28, 0.95), bg: (0, 0, 0, 0))
        let inset = size * 0.22
        let paperW = size - inset * 2
        let paperH = size - inset * 2
        renderer.addQuadPublic(to: &vertices, x: x + inset, y: y + inset, w: paperW, h: paperH,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.9, 0.9, 0.88, 1.0), bg: (0, 0, 0, 0))
        let lineInset = inset * 1.35
        let lineW = paperW - lineInset
        let lineH: Float = max(1, scaleFactor)
        for row in 0..<3 {
            let lineY = y + inset + size * 0.18 + Float(row) * size * 0.16
            renderer.addQuadPublic(to: &vertices, x: x + lineInset, y: lineY, w: lineW, h: lineH,
                                   tx: 0, ty: 0, tw: 0, th: 0,
                                   fg: (0.28, 0.34, 0.42, 1.0), bg: (0, 0, 0, 0))
        }
        drawVertices(vertices, encoder: encoder, pipeline: pipeline, viewportSize: viewportSize)
    }

    private func drawWorkspaceCloseButton(
        encoder: MTLRenderCommandEncoder,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.overlayPipeline else { return }
        var vertices: [Float] = []
        let x = Float(frame.origin.x) * scaleFactor
        let y = Float(frame.origin.y) * scaleFactor
        let size = Float(frame.width) * scaleFactor
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: size, h: size,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.35, 0.18, 0.18, 0.9), bg: (0, 0, 0, 0))
        let lineW: Float = 2.0 * scaleFactor
        renderer.addQuadPublic(to: &vertices, x: x + size * 0.25, y: y + size * 0.5 - lineW / 2,
                               w: size * 0.5, h: lineW, tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (1, 1, 1, 1), bg: (0, 0, 0, 0))
        drawVertices(vertices, encoder: encoder, pipeline: pipeline, viewportSize: viewportSize)
    }

    private func drawCloseButton(
        encoder: MTLRenderCommandEncoder,
        frame: NSRect,
        isHovered: Bool,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.overlayPipeline else { return }

        var vertices: [Float] = []
        let x = Float(frame.origin.x) * scaleFactor
        let y = Float(frame.origin.y) * scaleFactor
        let size = Float(frame.width) * scaleFactor

        // Circle background (approximate with a filled square for now)
        let alpha: Float = isHovered ? 0.8 : 0.3
        let bgColor: (Float, Float, Float) = isHovered ? (0.8, 0.2, 0.2) : (0.4, 0.4, 0.4)
        renderer.addQuadPublic(
            to: &vertices, x: x, y: y, w: size, h: size,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (bgColor.0, bgColor.1, bgColor.2, alpha),
            bg: (0, 0, 0, 0)
        )

        // X mark (two thin lines)
        let lineW: Float = 2.0 * scaleFactor
        let margin: Float = size * 0.25
        let cx = x + size / 2
        let cy = y + size / 2
        let halfLen = (size - margin * 2) / 2

        // Diagonal line 1 (approximate with a thin rectangle)
        renderer.addQuadPublic(
            to: &vertices,
            x: cx - halfLen, y: cy - lineW / 2,
            w: halfLen * 2, h: lineW,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (1, 1, 1, alpha),
            bg: (0, 0, 0, 0)
        )
        // Diagonal line 2
        renderer.addQuadPublic(
            to: &vertices,
            x: cx - lineW / 2, y: cy - halfLen,
            w: lineW, h: halfLen * 2,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (1, 1, 1, alpha),
            bg: (0, 0, 0, 0)
        )

        drawVertices(vertices, encoder: encoder, pipeline: pipeline, viewportSize: viewportSize)
    }

    private func drawAddButton(
        encoder: MTLRenderCommandEncoder,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        terminalCount: Int
    ) {
        guard let pipeline = renderer.overlayPipeline else { return }

        // Position: bottom-right corner
        let btnSize = Layout.addButtonSize
        let margin: CGFloat = 20
        let bx = bounds.width - btnSize - margin
        let by = bounds.height - btnSize - margin

        let x = Float(bx) * scaleFactor
        let y = Float(by) * scaleFactor
        let size = Float(btnSize) * scaleFactor

        var vertices: [Float] = []

        // Button background
        renderer.addQuadPublic(
            to: &vertices, x: x, y: y, w: size, h: size,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (0.3, 0.3, 0.3, 0.6),
            bg: (0, 0, 0, 0)
        )

        // Plus sign
        let lineW: Float = 3.0 * scaleFactor
        let lineLen: Float = size * 0.5
        let cx = x + size / 2
        let cy = y + size / 2

        // Horizontal
        renderer.addQuadPublic(
            to: &vertices,
            x: cx - lineLen / 2, y: cy - lineW / 2,
            w: lineLen, h: lineW,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (0.8, 0.8, 0.8, 0.9),
            bg: (0, 0, 0, 0)
        )
        // Vertical
        renderer.addQuadPublic(
            to: &vertices,
            x: cx - lineW / 2, y: cy - lineLen / 2,
            w: lineW, h: lineLen,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (0.8, 0.8, 0.8, 0.9),
            bg: (0, 0, 0, 0)
        )

        drawVertices(vertices, encoder: encoder, pipeline: pipeline, viewportSize: viewportSize)

        // Store the add button frame for hit testing
        addButtonFrame = NSRect(x: bx, y: by, width: btnSize, height: btnSize)
    }

    private func drawAddWorkspaceButton(
        encoder: MTLRenderCommandEncoder,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.overlayPipeline else { return }

        let btnSize = Layout.addButtonSize
        let margin: CGFloat = 20
        let spacing: CGFloat = 12
        let bx = bounds.width - btnSize * 2 - margin - spacing
        let by = bounds.height - btnSize - margin

        let x = Float(bx) * scaleFactor
        let y = Float(by) * scaleFactor
        let size = Float(btnSize) * scaleFactor
        var vertices: [Float] = []

        renderer.addQuadPublic(
            to: &vertices, x: x, y: y, w: size, h: size,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (0.18, 0.22, 0.18, 0.75),
            bg: (0, 0, 0, 0)
        )

        let lineW: Float = 3.0 * scaleFactor
        let lineLen: Float = size * 0.42
        let cx = x + size / 2
        let cy = y + size / 2
        renderer.addQuadPublic(
            to: &vertices,
            x: cx - lineLen / 2, y: cy - lineW / 2,
            w: lineLen, h: lineW,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (0.82, 0.9, 0.82, 1.0),
            bg: (0, 0, 0, 0)
        )
        renderer.addQuadPublic(
            to: &vertices,
            x: cx - lineW / 2, y: cy - lineLen / 2,
            w: lineW, h: lineLen,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (0.82, 0.9, 0.82, 1.0),
            bg: (0, 0, 0, 0)
        )
        let folderY = y + size * 0.22
        renderer.addQuadPublic(
            to: &vertices,
            x: x + size * 0.18, y: folderY,
            w: size * 0.64, h: size * 0.36,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (0.36, 0.48, 0.36, 0.95),
            bg: (0, 0, 0, 0)
        )
        drawVertices(vertices, encoder: encoder, pipeline: pipeline, viewportSize: viewportSize)
        addWorkspaceButtonFrame = NSRect(x: bx, y: by, width: btnSize, height: btnSize)
    }

    /// Check if the add button was clicked
    func checkAddButtonClick(at point: NSPoint) -> Bool {
        return addButtonFrame.contains(point)
    }

    private func drawVertices(
        _ vertices: [Float],
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        viewportSize: SIMD2<Float>
    ) {
        guard !vertices.isEmpty else { return }

        encoder.setRenderPipelineState(pipeline)
        let buf = renderer.makeTemporaryBuffer(vertices: vertices)
        if let buf = buf {
            var uniforms = MetalRenderer.MetalUniforms(
                viewportSize: viewportSize,
                cursorOpacity: 0,
                time: 0
            )
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalRenderer.MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: vertices.count / 12)
        }
    }
}

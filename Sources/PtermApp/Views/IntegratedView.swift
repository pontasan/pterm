import AppKit
import MetalKit

/// Displays all terminal sessions as a grid of live thumbnails.
///
/// Each thumbnail renders its terminal content at full PTY grid resolution,
/// scaled down by the GPU to fit the thumbnail cell. Clicking a thumbnail
/// switches to the focused (occupied) view. Shift+click enables multi-select
/// for split display.
final class IntegratedView: MTKView {
    /// Terminal manager
    private let manager: TerminalManager

    /// Metal renderer
    private let renderer: MetalRenderer

    /// Callback: user clicked a terminal thumbnail (single select).
    var onSelectTerminal: ((TerminalController) -> Void)?

    /// Callback: user wants to add a new terminal.
    var onAddTerminal: (() -> Void)?

    /// Set of currently selected terminals (for multi-select with Shift)
    private(set) var selectedTerminals: Set<UUID> = []

    /// Callback: user shift-clicked multiple terminals for split view.
    var onMultiSelect: (([TerminalController]) -> Void)?

    /// Tracking area for mouse hover (close buttons, etc.)
    private var trackingArea: NSTrackingArea?

    /// Index of the thumbnail currently under the mouse (for hover effects)
    private var hoveredIndex: Int?

    /// Index of the thumbnail whose close button is hovered
    private var hoveredCloseIndex: Int?

    /// Stored frame for the add button (updated each draw)
    private var addButtonFrame: NSRect = .zero

    /// Layout constants
    private struct Layout {
        static let thumbnailPadding: CGFloat = 12
        static let titleBarHeight: CGFloat = 24
        static let closeButtonSize: CGFloat = 16
        static let addButtonSize: CGFloat = 40
        static let cornerRadius: CGFloat = 6
        static let titleFontSize: CGFloat = 11
        static let borderWidth: CGFloat = 1.5
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

        updateTrackingArea()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var acceptsFirstResponder: Bool { true }

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

    /// Compute the frame for the N-th thumbnail in the grid.
    /// Returns (thumbnailFrame, titleFrame, closeButtonFrame).
    private func thumbnailFrames(count: Int) -> [(thumbnail: NSRect, title: NSRect, close: NSRect)] {
        guard count > 0 else { return [] }

        let (gridCols, gridRows) = TerminalManager.gridLayout(for: count)
        let pad = Layout.thumbnailPadding
        let titleH = Layout.titleBarHeight

        // Available space for grid (leave room for the add button at the bottom)
        let totalW = bounds.width - pad * 2
        let totalH = bounds.height - pad * 2
        let cellW = totalW / CGFloat(gridCols)
        let cellH = totalH / CGFloat(gridRows)

        var frames: [(NSRect, NSRect, NSRect)] = []
        for i in 0..<count {
            let gridCol = i % gridCols
            let gridRow = i / gridCols

            let cellX = pad + CGFloat(gridCol) * cellW
            let cellY = pad + CGFloat(gridRow) * cellH

            // Title bar at the top of each cell
            let titleFrame = NSRect(
                x: cellX + pad / 2,
                y: cellY + pad / 2,
                width: cellW - pad,
                height: titleH
            )

            // Thumbnail below the title bar
            let thumbFrame = NSRect(
                x: cellX + pad / 2,
                y: cellY + pad / 2 + titleH,
                width: cellW - pad,
                height: cellH - pad - titleH
            )

            // Close button in the top-left of the title bar
            let closeFrame = NSRect(
                x: titleFrame.origin.x + 4,
                y: titleFrame.origin.y + (titleH - Layout.closeButtonSize) / 2,
                width: Layout.closeButtonSize,
                height: Layout.closeButtonSize
            )

            frames.append((thumbFrame, titleFrame, closeFrame))
        }
        return frames
    }

    /// Return the index of the thumbnail at the given view-coordinates point.
    private func thumbnailIndex(at point: NSPoint) -> Int? {
        let count = manager.count
        guard count > 0 else { return nil }

        let frames = thumbnailFrames(count: count)
        // Point is in flipped coordinates (top = 0)
        for (i, f) in frames.enumerated() {
            // Check both title and thumbnail area
            let fullRect = f.title.union(f.thumbnail)
            if fullRect.contains(point) {
                return i
            }
        }
        return nil
    }

    /// Check if a point hits a close button.
    private func closeButtonIndex(at point: NSPoint) -> Int? {
        let count = manager.count
        guard count > 0 else { return nil }

        let frames = thumbnailFrames(count: count)
        for (i, f) in frames.enumerated() {
            // Slightly larger hit area for the close button
            let hitRect = f.close.insetBy(dx: -4, dy: -4)
            if hitRect.contains(point) {
                return i
            }
        }
        return nil
    }

    // MARK: - Flipped Coordinates

    override var isFlipped: Bool { true }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check add button
        if addButtonFrame.contains(point) {
            onAddTerminal?()
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

        let controller = manager.terminals[idx]

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

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredIndex = thumbnailIndex(at: point)
        hoveredCloseIndex = closeButtonIndex(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        hoveredCloseIndex = nil
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Cmd+T: new terminal (handled by menu, but also catch here)
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
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
            let frames = thumbnailFrames(count: count)

            for (i, controller) in terminals.enumerated() {
                guard i < frames.count else { break }
                let frame = frames[i]

                // Draw thumbnail border/background
                let isHovered = hoveredIndex == i
                let isSelected = selectedTerminals.contains(controller.id)

                drawThumbnailBackground(
                    encoder: encoder,
                    frame: frame.thumbnail,
                    titleFrame: frame.title,
                    isHovered: isHovered,
                    isSelected: isSelected,
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
        let borderAlpha: Float = isSelected ? 0.9 : (isHovered ? 0.6 : 0.3)
        let borderColor: (Float, Float, Float) = isSelected ? (0.3, 0.6, 1.0) : (0.4, 0.4, 0.4)
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

    private func drawTitle(
        encoder: MTLRenderCommandEncoder,
        title: String,
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


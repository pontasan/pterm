import Foundation
import Metal
import MetalKit
import QuartzCore

/// Metal-based terminal renderer.
///
/// Renders the terminal grid using GPU-accelerated drawing:
/// 1. Cell backgrounds as colored quads
/// 2. Glyphs sampled from the texture atlas
/// 3. Block cursor with smooth fade animation
/// 4. Scrollbar overlay when scrollback is available
///
/// Supports Retina (HiDPI) rendering and virtualized scrollback
/// (only visible rows are rendered, regardless of scrollback size).
final class MetalRenderer {
    /// Metal device
    let device: MTLDevice

    /// Command queue (accessible for IntegratedView)
    let commandQueue: MTLCommandQueue

    /// Render pipeline for cell backgrounds
    private(set) var bgPipeline: MTLRenderPipelineState?

    /// Render pipeline for glyphs
    private(set) var glyphPipeline: MTLRenderPipelineState?

    /// Render pipeline for cursor
    private(set) var cursorPipeline: MTLRenderPipelineState?

    /// Render pipeline for overlay (scrollbar, etc.)
    private(set) var overlayPipeline: MTLRenderPipelineState?

    /// Glyph atlas
    let glyphAtlas: GlyphAtlas

    /// Sampler state for glyph texture (nearest-neighbor for full-size)
    private var sampler: MTLSamplerState?

    /// Sampler state for thumbnails (linear filtering for scaled-down rendering)
    private var thumbnailSampler: MTLSamplerState?

    /// Public accessor for sampler (used by IntegratedView)
    var samplerState: MTLSamplerState? { sampler }

    /// Vertex data for current frame
    private var bgVertices: [Float] = []
    private var glyphVertices: [Float] = []
    private var cursorVertices: [Float] = []
    private var overlayVertices: [Float] = []

    /// MTLBuffers for vertex data (avoids 4KB setVertexBytes limit)
    private var bgBuffer: MTLBuffer?
    private var glyphBuffer: MTLBuffer?
    private var cursorBuffer: MTLBuffer?
    private var overlayBuffer: MTLBuffer?

    /// Uniform buffer
    private var uniforms = MetalUniforms()

    /// Animation start time
    private let startTime: CFTimeInterval = CACurrentMediaTime()

    /// Viewport size
    var viewportSize: SIMD2<Float> = .zero

    struct MetalUniforms {
        var viewportSize: SIMD2<Float> = .zero
        var cursorOpacity: Float = 1.0
        var time: Float = 0.0
    }

    /// Default font size (points) — matches macOS Terminal default
    static let defaultFontSize: CGFloat = 11.0

    /// Minimum font size
    static let minFontSize: CGFloat = 8.0

    /// Maximum font size
    static let maxFontSize: CGFloat = 72.0

    /// Font size step per Cmd+/Cmd- press
    static let fontSizeStep: CGFloat = 1.0

    /// Padding around the terminal grid (in points).
    /// 1 half-width character. Dynamic: scales with font size.
    /// DPI is handled by the renderer (points → pixels via scaleFactor).
    var gridPadding: CGFloat {
        glyphAtlas.cellWidth
    }

    /// Whether render pipelines are set up
    var hasPipelines: Bool {
        bgPipeline != nil && glyphPipeline != nil && cursorPipeline != nil && overlayPipeline != nil
    }

    /// Floats per vertex: position(2) + texCoord(2) + fgColor(4) + bgColor(4) = 12
    private let floatsPerVertex = 12

    init?(scaleFactor: CGFloat = 2.0) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return nil
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = queue

        self.glyphAtlas = GlyphAtlas(device: device, fontSize: MetalRenderer.defaultFontSize,
                                      scaleFactor: scaleFactor)

        setupSampler()
    }

    /// Update font size. Rebuilds the glyph atlas and recalculates cell metrics.
    func updateFontSize(_ newSize: CGFloat) {
        let clamped = min(MetalRenderer.maxFontSize, max(MetalRenderer.minFontSize, newSize))
        glyphAtlas.updateFont(name: glyphAtlas.fontName, size: clamped)
    }

    func updateFont(name: String, size: CGFloat) {
        let clamped = min(MetalRenderer.maxFontSize, max(MetalRenderer.minFontSize, size))
        glyphAtlas.updateFont(name: name, size: clamped)
    }

    /// Load Metal shaders and create render pipelines.
    /// Must be called after the Metal library is available.
    func setupPipelines(library: MTLLibrary) {
        // Background pipeline
        if let bgVertex = library.makeFunction(name: "bg_vertex"),
           let bgFragment = library.makeFunction(name: "bg_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = bgVertex
            desc.fragmentFunction = bgFragment
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            bgPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        // Glyph pipeline (with alpha blending)
        if let glyphVertex = library.makeFunction(name: "glyph_vertex"),
           let glyphFragment = library.makeFunction(name: "glyph_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = glyphVertex
            desc.fragmentFunction = glyphFragment
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            glyphPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        // Cursor pipeline (with alpha blending)
        if let cursorVertex = library.makeFunction(name: "bg_vertex"),
           let cursorFragment = library.makeFunction(name: "cursor_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = cursorVertex
            desc.fragmentFunction = cursorFragment
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            cursorPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        // Overlay pipeline (alpha blending, pass-through fragment)
        if let overlayVertex = library.makeFunction(name: "bg_vertex"),
           let overlayFragment = library.makeFunction(name: "overlay_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = overlayVertex
            desc.fragmentFunction = overlayFragment
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            overlayPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }
    }

    private func setupSampler() {
        let desc = MTLSamplerDescriptor()
        // Use nearest-neighbor filtering for pixel-crisp text rendering.
        // In a monospace terminal grid, glyph texels map 1:1 to screen pixels
        // at the atlas's native scale, so linear interpolation only adds blur.
        desc.minFilter = .nearest
        desc.magFilter = .nearest
        desc.mipFilter = .notMipmapped
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: desc)

        // Linear filtering for thumbnail rendering where glyphs are
        // scaled down by the GPU. Bilinear interpolation produces
        // smoother, more readable text at reduced sizes.
        let thumbDesc = MTLSamplerDescriptor()
        thumbDesc.minFilter = .linear
        thumbDesc.magFilter = .linear
        thumbDesc.mipFilter = .notMipmapped
        thumbDesc.sAddressMode = .clampToEdge
        thumbDesc.tAddressMode = .clampToEdge
        thumbnailSampler = device.makeSamplerState(descriptor: thumbDesc)
    }

    // MARK: - Vertex Buffer Management

    /// Update or create an MTLBuffer to hold the given vertex data.
    /// Reuses the existing buffer if it has sufficient capacity.
    private func updateVertexBuffer(_ buffer: inout MTLBuffer?, vertices: [Float]) -> MTLBuffer? {
        let byteCount = vertices.count * MemoryLayout<Float>.size
        guard byteCount > 0 else { return nil }

        if buffer == nil || buffer!.length < byteCount {
            // Allocate with 50% headroom to reduce reallocations
            let allocSize = byteCount + byteCount / 2
            buffer = device.makeBuffer(length: allocSize, options: .storageModeShared)
        }

        buffer?.contents().copyMemory(from: vertices, byteCount: byteCount)
        return buffer
    }

    // MARK: - Rendering

    /// Build vertex data from terminal model and render.
    /// When scrollOffset > 0, mixes scrollback rows with active grid rows
    /// to show historical content (virtualized: only visible rows are processed).
    func render(model: TerminalModel, scrollback: ScrollbackBuffer,
                scrollOffset: Int, selection: TerminalSelection?, in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // Update uniforms
        let drawableSize = view.drawableSize
        viewportSize = SIMD2<Float>(Float(drawableSize.width),
                                     Float(drawableSize.height))
        uniforms.viewportSize = viewportSize
        uniforms.time = Float(CACurrentMediaTime() - startTime)
        uniforms.cursorOpacity = (scrollOffset == 0 && model.cursor.visible) ? 1.0 : 0.0

        // Clear color: black background
        renderPassDescriptor.colorAttachments[0].clearColor =
            MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Build vertex data using the atlas's scale factor.
        let sf = Float(glyphAtlas.scaleFactor)
        buildVertexData(model: model, scrollback: scrollback, scrollOffset: scrollOffset,
                        selection: selection, scaleFactor: sf)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor) else {
            return
        }

        // 1. Draw backgrounds
        if !bgVertices.isEmpty, let pipeline = bgPipeline,
           let buf = updateVertexBuffer(&bgBuffer, vertices: bgVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: bgVertices.count / floatsPerVertex)
        }

        // 2. Draw glyphs
        if !glyphVertices.isEmpty, let pipeline = glyphPipeline,
           let atlas = glyphAtlas.texture,
           let buf = updateVertexBuffer(&glyphBuffer, vertices: glyphVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: glyphVertices.count / floatsPerVertex)
        }

        // 3. Draw cursor (only when at the bottom of scrollback)
        if !cursorVertices.isEmpty, let pipeline = cursorPipeline,
           let buf = updateVertexBuffer(&cursorBuffer, vertices: cursorVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: cursorVertices.count / floatsPerVertex)
        }

        // 4. Draw overlay (scrollbar)
        if !overlayVertices.isEmpty, let pipeline = overlayPipeline,
           let buf = updateVertexBuffer(&overlayBuffer, vertices: overlayVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: overlayVertices.count / floatsPerVertex)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Vertex Building

    private func buildVertexData(model: TerminalModel, scrollback: ScrollbackBuffer,
                                  scrollOffset: Int, selection: TerminalSelection?,
                                  scaleFactor: Float) {
        bgVertices.removeAll(keepingCapacity: true)
        glyphVertices.removeAll(keepingCapacity: true)
        cursorVertices.removeAll(keepingCapacity: true)
        overlayVertices.removeAll(keepingCapacity: true)

        let cellW = Float(glyphAtlas.cellWidth) * scaleFactor
        let cellH = Float(glyphAtlas.cellHeight) * scaleFactor
        let padX = Float(gridPadding) * scaleFactor
        let padY = Float(gridPadding) * scaleFactor

        let viewRows = model.rows
        let viewCols = model.cols
        let sbCount = scrollback.rowCount

        // Pre-fetch scrollback rows that are visible in the viewport.
        // Each row is fetched once and reused for all columns.
        var scrollbackRowCache: [Int: [Cell]] = [:]
        if scrollOffset > 0 {
            let firstAbsolute = max(0, sbCount - scrollOffset)
            for viewRow in 0..<viewRows {
                let absRow = firstAbsolute + viewRow
                if absRow >= 0 && absRow < sbCount {
                    scrollbackRowCache[absRow] = scrollback.getRow(at: absRow)
                }
            }
        }

        let firstAbsolute = scrollOffset > 0 ? max(0, sbCount - scrollOffset) : sbCount

        for row in 0..<viewRows {
            let absoluteRow = firstAbsolute + row
            let isScrollbackRow = absoluteRow < sbCount
            let scrollbackRow = isScrollbackRow ? scrollbackRowCache[absoluteRow] : nil
            let gridRow = isScrollbackRow ? -1 : absoluteRow - sbCount

            for col in 0..<viewCols {
                let cell: Cell
                if let sbRow = scrollbackRow {
                    cell = col < sbRow.count ? sbRow[col] : .empty
                } else {
                    cell = model.grid.cell(at: gridRow, col: col)
                }

                // Skip continuation cells of wide characters
                if cell.isWideContinuation { continue }

                let x = padX + Float(col) * cellW
                let y = padY + Float(row) * cellH
                let w = cellW * Float(max(1, cell.width))
                let h = cellH

                // Resolve colors (handle inverse and selection)
                var fgColor: (r: Float, g: Float, b: Float)
                var bgColor: (r: Float, g: Float, b: Float)

                let isSelected = selection?.contains(row: row, col: col) ?? false

                if cell.attributes.inverse != isSelected {
                    // Inverse XOR selected: swap fg/bg
                    fgColor = cell.attributes.background.resolve(isForeground: false)
                    bgColor = cell.attributes.foreground.resolve(isForeground: true)
                } else {
                    fgColor = resolveForegroundColor(for: cell)
                    bgColor = cell.attributes.background.resolve(isForeground: false)
                }

                if cell.attributes.hidden {
                    fgColor = bgColor
                } else if cell.attributes.dim {
                    fgColor = (fgColor.r * 0.66, fgColor.g * 0.66, fgColor.b * 0.66)
                }

                // Background quad (skip if default black to save draw calls, but always draw for selected cells)
                if isSelected || bgColor.r > 0.001 || bgColor.g > 0.001 || bgColor.b > 0.001 {
                    addQuad(to: &bgVertices, x: x, y: y, w: w, h: h,
                           tx: 0, ty: 0, tw: 0, th: 0,
                           fg: (bgColor.r, bgColor.g, bgColor.b, 1),
                           bg: (bgColor.r, bgColor.g, bgColor.b, 1))
                }

                // Block/quadrant elements render more faithfully as geometry.
                if renderBlockElementIfNeeded(
                    codepoint: cell.codepoint,
                    x: x, y: y, w: w, h: h,
                    color: fgColor
                ) {
                    // no-op
                } else if cell.codepoint > 0x20, // Skip spaces
                   let glyph = glyphAtlas.glyphInfo(for: cell.codepoint),
                   glyph.pixelWidth > 0 {

                    let glyphAdvance = max(0, glyph.advance * scaleFactor)
                    let centeredOffset = max(0, (w - glyphAdvance) * 0.5)
                    let glyphX = x + centeredOffset + Float(glyph.bearingX) * scaleFactor
                    // Position glyph so its baseline (at baselineOffset pixels from
                    // the bitmap top) aligns with the cell's baseline screen position.
                    let baselineScreenY = y + cellH - Float(glyphAtlas.baseline) * scaleFactor
                    let glyphY = baselineScreenY - glyph.baselineOffset
                    let glyphW = Float(glyph.pixelWidth)
                    let glyphH = Float(glyph.pixelHeight)

                    addQuad(to: &glyphVertices,
                           x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                           tx: glyph.textureX, ty: glyph.textureY,
                           tw: glyph.textureW, th: glyph.textureH,
                           fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                           bg: (0, 0, 0, 0))

                    if cell.attributes.bold {
                        let boldOffset = max(1.0, scaleFactor) * 0.5
                        addQuad(to: &glyphVertices,
                               x: glyphX + boldOffset, y: glyphY, w: glyphW, h: glyphH,
                               tx: glyph.textureX, ty: glyph.textureY,
                               tw: glyph.textureW, th: glyph.textureH,
                               fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                               bg: (0, 0, 0, 0))
                    }
                }

                if cell.attributes.underline {
                    let underlineThickness = max(1.0, scaleFactor)
                    let underlineY = y + h - underlineThickness
                    addQuad(to: &overlayVertices, x: x, y: underlineY, w: w, h: underlineThickness,
                           tx: 0, ty: 0, tw: 0, th: 0,
                           fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                           bg: (fgColor.r, fgColor.g, fgColor.b, 1))
                }

                if cell.attributes.strikethrough {
                    let strikeThickness = max(1.0, scaleFactor)
                    let strikeY = y + (h * 0.5) - (strikeThickness * 0.5)
                    addQuad(to: &overlayVertices, x: x, y: strikeY, w: w, h: strikeThickness,
                           tx: 0, ty: 0, tw: 0, th: 0,
                           fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                           bg: (fgColor.r, fgColor.g, fgColor.b, 1))
                }
            }
        }

        // Cursor (only visible when not scrolled back)
        if scrollOffset == 0 && model.cursor.visible {
            let cx = padX + Float(model.cursor.col) * cellW
            let cy = padY + Float(model.cursor.row) * cellH
            addQuad(to: &cursorVertices, x: cx, y: cy, w: cellW, h: cellH,
                   tx: 0, ty: 0, tw: 0, th: 0,
                   fg: (0.8, 0.8, 0.8, 1),
                   bg: (0.8, 0.8, 0.8, 1))
        }

        // Scrollbar is handled by NSScroller overlay in TerminalView
    }

    private func resolveForegroundColor(for cell: Cell) -> (r: Float, g: Float, b: Float) {
        if cell.attributes.bold,
           case .indexed(let idx) = cell.attributes.foreground,
           idx < 8 {
            return TerminalColor.indexed(idx + 8).resolve(isForeground: true)
        }

        return cell.attributes.foreground.resolve(isForeground: true)
    }

    @discardableResult
    private func renderBlockElementIfNeeded(
        codepoint: UInt32,
        x: Float,
        y: Float,
        w: Float,
        h: Float,
        color: (r: Float, g: Float, b: Float)
    ) -> Bool {
        let rects = blockElementRects(for: codepoint, width: w, height: h)
        guard !rects.isEmpty else { return false }

        for rect in rects {
            addQuad(to: &overlayVertices,
                   x: x + rect.x, y: y + rect.y, w: rect.w, h: rect.h,
                   tx: 0, ty: 0, tw: 0, th: 0,
                   fg: (color.r, color.g, color.b, 1),
                   bg: (color.r, color.g, color.b, 1))
        }
        return true
    }

    private func blockElementRects(
        for codepoint: UInt32,
        width: Float,
        height: Float
    ) -> [(x: Float, y: Float, w: Float, h: Float)] {
        let halfW = width * 0.5
        let halfH = height * 0.5
        let quarterH = max(1.0, height * 0.25)
        let eighthW = max(1.0, width * 0.125)

        switch codepoint {
        case 0x2580:
            return [(0, 0, width, halfH)]
        case 0x2581:
            return [(0, height - quarterH, width, quarterH)]
        case 0x2584:
            return [(0, halfH, width, halfH)]
        case 0x2588:
            return [(0, 0, width, height)]
        case 0x258C:
            return [(0, 0, halfW, height)]
        case 0x258F:
            return [(0, 0, eighthW, height)]
        case 0x2590:
            return [(halfW, 0, halfW, height)]
        case 0x2595:
            return [(width - eighthW, 0, eighthW, height)]
        case 0x2596:
            return [(0, halfH, halfW, halfH)]
        case 0x2597:
            return [(halfW, halfH, halfW, halfH)]
        case 0x2598:
            return [(0, 0, halfW, halfH)]
        case 0x2599:
            return [(0, 0, halfW, halfH), (0, halfH, width, halfH)]
        case 0x259A:
            return [(0, 0, halfW, halfH), (halfW, halfH, halfW, halfH)]
        case 0x259B:
            return [(0, 0, width, halfH), (0, halfH, halfW, halfH)]
        case 0x259C:
            return [(0, 0, width, halfH), (halfW, halfH, halfW, halfH)]
        case 0x259D:
            return [(halfW, 0, halfW, halfH)]
        case 0x259E:
            return [(halfW, 0, halfW, halfH), (0, halfH, halfW, halfH)]
        case 0x259F:
            return [(halfW, 0, halfW, halfH), (0, halfH, width, halfH)]
        default:
            return []
        }
    }

    /// Add a quad (2 triangles = 6 vertices) to the vertex array.
    private func addQuad(to vertices: inout [Float],
                        x: Float, y: Float, w: Float, h: Float,
                        tx: Float, ty: Float, tw: Float, th: Float,
                        fg: (r: Float, g: Float, b: Float, a: Float),
                        bg: (r: Float, g: Float, b: Float, a: Float)) {
        // Triangle 1: top-left, top-right, bottom-left
        vertices.append(contentsOf: [x,     y,     tx,      ty,      fg.r, fg.g, fg.b, fg.a, bg.r, bg.g, bg.b, bg.a])
        vertices.append(contentsOf: [x + w, y,     tx + tw, ty,      fg.r, fg.g, fg.b, fg.a, bg.r, bg.g, bg.b, bg.a])
        vertices.append(contentsOf: [x,     y + h, tx,      ty + th, fg.r, fg.g, fg.b, fg.a, bg.r, bg.g, bg.b, bg.a])
        // Triangle 2: top-right, bottom-right, bottom-left
        vertices.append(contentsOf: [x + w, y,     tx + tw, ty,      fg.r, fg.g, fg.b, fg.a, bg.r, bg.g, bg.b, bg.a])
        vertices.append(contentsOf: [x + w, y + h, tx + tw, ty + th, fg.r, fg.g, fg.b, fg.a, bg.r, bg.g, bg.b, bg.a])
        vertices.append(contentsOf: [x,     y + h, tx,      ty + th, fg.r, fg.g, fg.b, fg.a, bg.r, bg.g, bg.b, bg.a])
    }

    // MARK: - Public API for IntegratedView

    /// Public quad builder (same as addQuad, accessible by IntegratedView).
    func addQuadPublic(to vertices: inout [Float],
                       x: Float, y: Float, w: Float, h: Float,
                       tx: Float, ty: Float, tw: Float, th: Float,
                       fg: (r: Float, g: Float, b: Float, a: Float),
                       bg: (r: Float, g: Float, b: Float, a: Float)) {
        addQuad(to: &vertices, x: x, y: y, w: w, h: h,
                tx: tx, ty: ty, tw: tw, th: th, fg: fg, bg: bg)
    }

    /// Create a one-shot MTLBuffer from vertex data.
    func makeTemporaryBuffer(vertices: [Float]) -> MTLBuffer? {
        let byteCount = vertices.count * MemoryLayout<Float>.size
        guard byteCount > 0 else { return nil }
        let buffer = device.makeBuffer(bytes: vertices, length: byteCount, options: .storageModeShared)
        return buffer
    }

    // MARK: - Thumbnail Rendering

    /// Render terminal content scaled down into a thumbnail rectangle.
    ///
    /// Builds vertex data for the terminal grid at full resolution, then
    /// applies a linear transform to map all positions into `thumbnailRect`
    /// within the drawable. This is the GPU-scaled rendering path used by
    /// the integrated view.
    ///
    /// - Parameters:
    ///   - model: Terminal model with grid data.
    ///   - scrollback: Scrollback buffer.
    ///   - scrollOffset: Current scroll offset.
    ///   - encoder: Active render command encoder to draw into.
    ///   - viewportSize: Size of the drawable in pixels.
    ///   - thumbnailRect: Destination rectangle in points (flipped Y: origin = top-left).
    ///   - scaleFactor: Display scale factor.
    func renderThumbnail(model: TerminalModel, scrollback: ScrollbackBuffer,
                         scrollOffset: Int, encoder: MTLRenderCommandEncoder,
                         viewportSize: SIMD2<Float>, thumbnailRect: NSRect,
                         scaleFactor: Float) {
        var thumbBgVertices: [Float] = []
        var thumbGlyphVertices: [Float] = []

        let cellW = Float(glyphAtlas.cellWidth) * scaleFactor
        let cellH = Float(glyphAtlas.cellHeight) * scaleFactor
        let padX = Float(gridPadding) * scaleFactor
        let padY = Float(gridPadding) * scaleFactor

        let viewRows = model.rows
        let viewCols = model.cols

        // Compute the full terminal size in pixels (as if rendering at full size)
        let termW = padX * 2 + Float(viewCols) * cellW
        let termH = padY * 2 + Float(viewRows) * cellH

        // Thumbnail destination in pixels
        let thumbX = Float(thumbnailRect.origin.x) * scaleFactor
        let thumbY = Float(thumbnailRect.origin.y) * scaleFactor
        let thumbW = Float(thumbnailRect.width) * scaleFactor
        let thumbH = Float(thumbnailRect.height) * scaleFactor

        // Scale to map terminal pixels → thumbnail pixels
        let scaleX = thumbW / termW
        let scaleY = thumbH / termH
        // Use uniform scale to maintain aspect ratio
        let thumbScale = min(scaleX, scaleY)

        // Center within thumbnail rect
        let scaledW = termW * thumbScale
        let scaledH = termH * thumbScale
        let offsetX = thumbX + (thumbW - scaledW) / 2
        let offsetY = thumbY + (thumbH - scaledH) / 2

        let sbCount = scrollback.rowCount
        var scrollbackRowCache: [Int: [Cell]] = [:]
        if scrollOffset > 0 {
            let firstAbsolute = max(0, sbCount - scrollOffset)
            for viewRow in 0..<viewRows {
                let absRow = firstAbsolute + viewRow
                if absRow >= 0 && absRow < sbCount {
                    scrollbackRowCache[absRow] = scrollback.getRow(at: absRow)
                }
            }
        }

        let firstAbsolute = scrollOffset > 0 ? max(0, sbCount - scrollOffset) : sbCount

        for row in 0..<viewRows {
            let absoluteRow = firstAbsolute + row
            let isScrollbackRow = absoluteRow < sbCount
            let scrollbackRow = isScrollbackRow ? scrollbackRowCache[absoluteRow] : nil
            let gridRow = isScrollbackRow ? -1 : absoluteRow - sbCount

            for col in 0..<viewCols {
                let cell: Cell
                if let sbRow = scrollbackRow {
                    cell = col < sbRow.count ? sbRow[col] : .empty
                } else {
                    cell = model.grid.cell(at: gridRow, col: col)
                }

                if cell.isWideContinuation { continue }

                // Full-size position
                let fullX = padX + Float(col) * cellW
                let fullY = padY + Float(row) * cellH
                let fullW = cellW * Float(max(1, cell.width))
                let fullH = cellH

                // Transform to thumbnail space
                let x = offsetX + fullX * thumbScale
                let y = offsetY + fullY * thumbScale
                let w = fullW * thumbScale
                let h = fullH * thumbScale

                // Resolve colors
                var fgColor: (r: Float, g: Float, b: Float)
                var bgColor: (r: Float, g: Float, b: Float)

                if cell.attributes.inverse {
                    fgColor = cell.attributes.background.resolve(isForeground: false)
                    bgColor = cell.attributes.foreground.resolve(isForeground: true)
                } else {
                    fgColor = cell.attributes.foreground.resolve(isForeground: true)
                    bgColor = cell.attributes.background.resolve(isForeground: false)
                }

                // Background
                if bgColor.r > 0.001 || bgColor.g > 0.001 || bgColor.b > 0.001 {
                    addQuad(to: &thumbBgVertices, x: x, y: y, w: w, h: h,
                           tx: 0, ty: 0, tw: 0, th: 0,
                           fg: (bgColor.r, bgColor.g, bgColor.b, 1),
                           bg: (bgColor.r, bgColor.g, bgColor.b, 1))
                }

                // Glyph
                if cell.codepoint > 0x20,
                   let glyph = glyphAtlas.glyphInfo(for: cell.codepoint),
                   glyph.pixelWidth > 0 {

                    let glyphFullX = fullX + Float(glyph.bearingX) * scaleFactor
                    let baselineScreenY = fullY + fullH - Float(glyphAtlas.baseline) * scaleFactor
                    let glyphFullY = baselineScreenY - glyph.baselineOffset
                    let glyphFullW = Float(glyph.pixelWidth)
                    let glyphFullH = Float(glyph.pixelHeight)

                    // Transform glyph to thumbnail space
                    let gx = offsetX + glyphFullX * thumbScale
                    let gy = offsetY + glyphFullY * thumbScale
                    let gw = glyphFullW * thumbScale
                    let gh = glyphFullH * thumbScale

                    addQuad(to: &thumbGlyphVertices,
                           x: gx, y: gy, w: gw, h: gh,
                           tx: glyph.textureX, ty: glyph.textureY,
                           tw: glyph.textureW, th: glyph.textureH,
                           fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                           bg: (0, 0, 0, 0))
                }
            }
        }

        // Draw thumbnail backgrounds
        var thumbUniforms = MetalUniforms(viewportSize: viewportSize, cursorOpacity: 0, time: 0)

        if !thumbBgVertices.isEmpty, let pipeline = bgPipeline,
           let buf = makeTemporaryBuffer(vertices: thumbBgVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&thumbUniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: thumbBgVertices.count / floatsPerVertex)
        }

        // Draw thumbnail glyphs (linear filtering for scaled-down text)
        if !thumbGlyphVertices.isEmpty, let pipeline = glyphPipeline,
           let atlas = glyphAtlas.texture,
           let buf = makeTemporaryBuffer(vertices: thumbGlyphVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&thumbUniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.setFragmentSamplerState(thumbnailSampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: thumbGlyphVertices.count / floatsPerVertex)
        }
    }
}

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

    /// Per-view buffer set to avoid conflicts when multiple MTKViews share this renderer.
    final class ViewBufferSet {
        var bgBuffer: MTLBuffer?
        var glyphBuffer: MTLBuffer?
        var cursorBuffer: MTLBuffer?
        var overlayBuffer: MTLBuffer?
        var borderBuffer: MTLBuffer?
    }

    /// Border configuration for split-view rendering.
    struct BorderConfig {
        let color: (Float, Float, Float, Float)
        let width: Float
    }

    /// Keyed by view's ObjectIdentifier to give each MTKView its own buffers.
    private var viewBuffers: [ObjectIdentifier: ViewBufferSet] = [:]

    private func bufferSet(for view: MTKView) -> ViewBufferSet {
        let key = ObjectIdentifier(view)
        if let existing = viewBuffers[key] { return existing }
        let bs = ViewBufferSet()
        viewBuffers[key] = bs
        return bs
    }

    /// Remove buffer set when a view is deallocated.
    func removeBuffers(for view: MTKView) {
        viewBuffers.removeValue(forKey: ObjectIdentifier(view))
    }

    /// Animation start time
    private let startTime: CFTimeInterval = CACurrentMediaTime()

    /// Viewport size
    var viewportSize: SIMD2<Float> = .zero

    struct MetalUniforms {
        var viewportSize: SIMD2<Float> = .zero
        var cursorOpacity: Float = 1.0
        var cursorBlink: Float = 1.0
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
    /// Search match info for rendering highlights.
    struct SearchHighlight {
        let matches: [TerminalController.SearchMatch]
        let currentIndex: Int?
    }

    /// Link hover underline range (view-relative row, startCol, endCol).
    struct LinkUnderline {
        let row: Int
        let startCol: Int
        let endCol: Int
    }

    func render(model: TerminalModel, scrollback: ScrollbackBuffer,
                scrollOffset: Int, selection: TerminalSelection?,
                searchHighlight: SearchHighlight? = nil,
                linkUnderline: LinkUnderline? = nil,
                borderConfig: BorderConfig? = nil,
                in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // Build local uniforms (avoid shared mutable state across concurrent renders)
        let drawableSize = view.drawableSize
        let vp = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        var uniforms = MetalUniforms(
            viewportSize: vp,
            cursorOpacity: (scrollOffset == 0 && model.cursor.visible) ? 1.0 : 0.0,
            cursorBlink: model.cursor.blinking ? 1.0 : 0.0,
            time: Float(CACurrentMediaTime() - startTime)
        )

        // Clear color: black background
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor =
            MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Build vertex data using the atlas's scale factor.
        let sf = Float(glyphAtlas.scaleFactor)
        let vd = buildVertexData(model: model, scrollback: scrollback, scrollOffset: scrollOffset,
                                 selection: selection, searchHighlight: searchHighlight,
                                 linkUnderline: linkUnderline, scaleFactor: sf)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor) else {
            return
        }

        // Use per-view buffer set to avoid conflicts when multiple MTKViews share this renderer.
        let bs = bufferSet(for: view)

        // 1. Draw backgrounds
        if !vd.bgVertices.isEmpty, let pipeline = bgPipeline,
           let buf = updateVertexBuffer(&bs.bgBuffer, vertices: vd.bgVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: vd.bgVertices.count / floatsPerVertex)
        }

        // 2. Draw glyphs
        if !vd.glyphVertices.isEmpty, let pipeline = glyphPipeline,
           let atlas = glyphAtlas.texture,
           let buf = updateVertexBuffer(&bs.glyphBuffer, vertices: vd.glyphVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: vd.glyphVertices.count / floatsPerVertex)
        }

        // 3. Draw cursor (only when at the bottom of scrollback)
        if !vd.cursorVertices.isEmpty, let pipeline = cursorPipeline,
           let buf = updateVertexBuffer(&bs.cursorBuffer, vertices: vd.cursorVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: vd.cursorVertices.count / floatsPerVertex)
        }

        // 4. Draw overlay (underline, strikethrough, block elements)
        if !vd.overlayVertices.isEmpty, let pipeline = overlayPipeline,
           let buf = updateVertexBuffer(&bs.overlayBuffer, vertices: vd.overlayVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: vd.overlayVertices.count / floatsPerVertex)
        }

        // 5. Draw border (for split view focus indication)
        if let border = borderConfig, let pipeline = overlayPipeline {
            var bv: [Float] = []
            let vw = vp.x
            let vh = vp.y
            let bw = border.width * Float(glyphAtlas.scaleFactor)
            let c = border.color
            // Top
            addQuad(to: &bv, x: 0, y: 0, w: vw, h: bw, tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            // Bottom
            addQuad(to: &bv, x: 0, y: vh - bw, w: vw, h: bw, tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            // Left
            addQuad(to: &bv, x: 0, y: bw, w: bw, h: vh - 2 * bw, tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            // Right
            addQuad(to: &bv, x: vw - bw, y: bw, w: bw, h: vh - 2 * bw, tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            if let buf = updateVertexBuffer(&bs.borderBuffer, vertices: bv) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                      vertexCount: bv.count / floatsPerVertex)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Vertex Building

    /// Result of building vertex data for a single frame.
    struct VertexData {
        var bgVertices: [Float] = []
        var glyphVertices: [Float] = []
        var cursorVertices: [Float] = []
        var overlayVertices: [Float] = []
    }

    private func buildVertexData(model: TerminalModel, scrollback: ScrollbackBuffer,
                                  scrollOffset: Int, selection: TerminalSelection?,
                                  searchHighlight: SearchHighlight? = nil,
                                  linkUnderline: LinkUnderline? = nil,
                                  scaleFactor: Float) -> VertexData {
        var vd = VertexData()

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

        // Build search match lookup: absoluteRow -> [(startCol, endCol, isCurrent)]
        var searchMatchesByRow: [Int: [(start: Int, end: Int, isCurrent: Bool)]] = [:]
        if let sh = searchHighlight {
            for (i, match) in sh.matches.enumerated() {
                let isCurrent = sh.currentIndex == i
                searchMatchesByRow[match.absoluteRow, default: []].append(
                    (start: match.startCol, end: match.endCol, isCurrent: isCurrent))
            }
        }

        for row in 0..<viewRows {
            let absoluteRow = firstAbsolute + row
            let isScrollbackRow = absoluteRow < sbCount
            let scrollbackRow = isScrollbackRow ? scrollbackRowCache[absoluteRow] : nil
            let gridRow = isScrollbackRow ? -1 : absoluteRow - sbCount

            // Pre-check which columns in this row have search highlights
            let rowMatches = searchMatchesByRow[absoluteRow]

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

                // Check if this cell is in a search match
                var searchMatchType: Int = 0 // 0=none, 1=match, 2=current match
                if let matches = rowMatches {
                    for m in matches {
                        if col >= m.start && col <= m.end {
                            searchMatchType = m.isCurrent ? 2 : 1
                            break
                        }
                    }
                }

                if cell.attributes.inverse != isSelected {
                    // Inverse XOR selected: swap fg/bg
                    fgColor = cell.attributes.background.resolve(isForeground: false)
                    bgColor = cell.attributes.foreground.resolve(isForeground: true)
                } else {
                    fgColor = resolveForegroundColor(for: cell)
                    bgColor = cell.attributes.background.resolve(isForeground: false)
                }

                // Apply search match highlight
                if searchMatchType == 2 {
                    // Current match: bright orange background, dark foreground
                    bgColor = (0.90, 0.60, 0.10)
                    fgColor = (0.0, 0.0, 0.0)
                } else if searchMatchType == 1 {
                    // Other matches: dim yellow background
                    bgColor = (0.55, 0.45, 0.10)
                    fgColor = (0.0, 0.0, 0.0)
                }

                if cell.attributes.hidden {
                    fgColor = bgColor
                } else if cell.attributes.dim && searchMatchType == 0 {
                    fgColor = (fgColor.r * 0.66, fgColor.g * 0.66, fgColor.b * 0.66)
                }

                // Background quad (skip if default black to save draw calls, but always draw for selected/highlighted cells)
                if isSelected || searchMatchType > 0 || bgColor.r > 0.001 || bgColor.g > 0.001 || bgColor.b > 0.001 {
                    addQuad(to: &vd.bgVertices, x: x, y: y, w: w, h: h,
                           tx: 0, ty: 0, tw: 0, th: 0,
                           fg: (bgColor.r, bgColor.g, bgColor.b, 1),
                           bg: (bgColor.r, bgColor.g, bgColor.b, 1))
                }

                // Block/quadrant elements render more faithfully as geometry.
                if renderBlockElementIfNeeded(
                    codepoint: cell.codepoint,
                    x: x, y: y, w: w, h: h,
                    color: fgColor,
                    vertices: &vd.overlayVertices
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

                    addQuad(to: &vd.glyphVertices,
                           x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                           tx: glyph.textureX, ty: glyph.textureY,
                           tw: glyph.textureW, th: glyph.textureH,
                           fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                           bg: (0, 0, 0, 0))

                    if cell.attributes.bold {
                        let boldOffset = max(1.0, scaleFactor) * 0.5
                        addQuad(to: &vd.glyphVertices,
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
                    addQuad(to: &vd.overlayVertices, x: x, y: underlineY, w: w, h: underlineThickness,
                           tx: 0, ty: 0, tw: 0, th: 0,
                           fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                           bg: (fgColor.r, fgColor.g, fgColor.b, 1))
                }

                if cell.attributes.strikethrough {
                    let strikeThickness = max(1.0, scaleFactor)
                    let strikeY = y + (h * 0.5) - (strikeThickness * 0.5)
                    addQuad(to: &vd.overlayVertices, x: x, y: strikeY, w: w, h: strikeThickness,
                           tx: 0, ty: 0, tw: 0, th: 0,
                           fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                           bg: (fgColor.r, fgColor.g, fgColor.b, 1))
                }

                // URL hover underline
                if let link = linkUnderline,
                   row == link.row && col >= link.startCol && col <= link.endCol {
                    let underlineThickness = max(1.0, scaleFactor)
                    let underlineY = y + h - underlineThickness
                    // Blue underline for link hover
                    addQuad(to: &vd.overlayVertices, x: x, y: underlineY, w: w, h: underlineThickness,
                           tx: 0, ty: 0, tw: 0, th: 0,
                           fg: (0.4, 0.6, 1.0, 1.0),
                           bg: (0.4, 0.6, 1.0, 1.0))
                }
            }
        }

        // Cursor (only visible when not scrolled back)
        if scrollOffset == 0 && model.cursor.visible {
            let cx = padX + Float(model.cursor.col) * cellW
            let cy = padY + Float(model.cursor.row) * cellH
            let cursorColor: (Float, Float, Float, Float) = (0.8, 0.8, 0.8, 1)

            switch model.cursor.shape {
            case .block:
                addQuad(to: &vd.cursorVertices, x: cx, y: cy, w: cellW, h: cellH,
                       tx: 0, ty: 0, tw: 0, th: 0,
                       fg: cursorColor, bg: cursorColor)
            case .underline:
                let thickness = max(1.0, scaleFactor * 2.0)
                addQuad(to: &vd.cursorVertices, x: cx, y: cy + cellH - thickness,
                       w: cellW, h: thickness,
                       tx: 0, ty: 0, tw: 0, th: 0,
                       fg: cursorColor, bg: cursorColor)
            case .bar:
                let thickness = max(1.0, scaleFactor * 2.0)
                addQuad(to: &vd.cursorVertices, x: cx, y: cy,
                       w: thickness, h: cellH,
                       tx: 0, ty: 0, tw: 0, th: 0,
                       fg: cursorColor, bg: cursorColor)
            }
        }

        // Scrollbar is handled by NSScroller overlay in TerminalView
        return vd
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
        color: (r: Float, g: Float, b: Float),
        vertices: inout [Float]
    ) -> Bool {
        let rects = blockElementRects(for: codepoint, width: w, height: h)
        guard !rects.isEmpty else { return false }

        for rect in rects {
            addQuad(to: &vertices,
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

    // MARK: - Split Cell Rendering

    /// Render a terminal at full (1:1) size into a specific rectangle within a shared render pass.
    /// Used by SplitRenderView to render all split terminals into a single MTKView,
    /// avoiding macOS CAMetalLayer compositing issues with multiple Metal layers.
    ///
    /// Vertex positions from buildVertexData are offset by cellRect's origin.
    /// A scissor rect clips rendering to the cell bounds.
    func renderSplitCell(model: TerminalModel, scrollback: ScrollbackBuffer,
                         scrollOffset: Int, selection: TerminalSelection?,
                         searchHighlight: SearchHighlight? = nil,
                         linkUnderline: LinkUnderline? = nil,
                         borderConfig: BorderConfig? = nil,
                         encoder: MTLRenderCommandEncoder,
                         viewportSize: SIMD2<Float>,
                         cellRect: NSRect,
                         scaleFactor: Float) {
        // Build vertex data at full size (positions relative to (0,0))
        let vd = buildVertexData(model: model, scrollback: scrollback, scrollOffset: scrollOffset,
                                 selection: selection, searchHighlight: searchHighlight,
                                 linkUnderline: linkUnderline, scaleFactor: scaleFactor)

        // Pixel offset for this cell
        let offsetX = Float(cellRect.origin.x) * scaleFactor
        let offsetY = Float(cellRect.origin.y) * scaleFactor
        let cellPixelW = Float(cellRect.width) * scaleFactor
        let cellPixelH = Float(cellRect.height) * scaleFactor

        // Scissor rect must be wholly contained within the drawable.
        // Clamp to drawable bounds to avoid Metal validation errors.
        let drawableW = Int(viewportSize.x)
        let drawableH = Int(viewportSize.y)
        let sx = max(0, min(Int(offsetX), drawableW - 1))
        let sy = max(0, min(Int(offsetY), drawableH - 1))
        let sw = max(1, min(Int(cellPixelW), drawableW - sx))
        let sh = max(1, min(Int(cellPixelH), drawableH - sy))
        let scissor = MTLScissorRect(x: sx, y: sy, width: sw, height: sh)
        encoder.setScissorRect(scissor)

        var uniforms = MetalUniforms(
            viewportSize: viewportSize,
            cursorOpacity: (scrollOffset == 0 && model.cursor.visible) ? 1.0 : 0.0,
            cursorBlink: model.cursor.blinking ? 1.0 : 0.0,
            time: Float(CACurrentMediaTime() - startTime)
        )

        // Offset all vertex positions by the cell origin
        func offsetVertices(_ vertices: [Float]) -> [Float] {
            guard !vertices.isEmpty else { return vertices }
            var result = vertices
            let vertexStride = floatsPerVertex
            var i = 0
            while i < result.count {
                result[i] += offsetX      // x position
                result[i + 1] += offsetY  // y position
                i += vertexStride
            }
            return result
        }

        // 1. Backgrounds
        let bgOffset = offsetVertices(vd.bgVertices)
        if !bgOffset.isEmpty, let pipeline = bgPipeline,
           let buf = makeTemporaryBuffer(vertices: bgOffset) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: bgOffset.count / floatsPerVertex)
        }

        // 2. Glyphs
        let glyphOffset = offsetVertices(vd.glyphVertices)
        if !glyphOffset.isEmpty, let pipeline = glyphPipeline,
           let atlas = glyphAtlas.texture,
           let buf = makeTemporaryBuffer(vertices: glyphOffset) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: glyphOffset.count / floatsPerVertex)
        }

        // 3. Cursor
        let cursorOffset = offsetVertices(vd.cursorVertices)
        if !cursorOffset.isEmpty, let pipeline = cursorPipeline,
           let buf = makeTemporaryBuffer(vertices: cursorOffset) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: cursorOffset.count / floatsPerVertex)
        }

        // 4. Overlay (underline, strikethrough, block elements)
        let overlayOffset = offsetVertices(vd.overlayVertices)
        if !overlayOffset.isEmpty, let pipeline = overlayPipeline,
           let buf = makeTemporaryBuffer(vertices: overlayOffset) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: overlayOffset.count / floatsPerVertex)
        }

        // 5. Border (focus indicator)
        if let border = borderConfig, let pipeline = overlayPipeline {
            var bv: [Float] = []
            let bw = border.width * scaleFactor
            let c = border.color
            // Top
            addQuad(to: &bv, x: offsetX, y: offsetY, w: cellPixelW, h: bw,
                   tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            // Bottom
            addQuad(to: &bv, x: offsetX, y: offsetY + cellPixelH - bw, w: cellPixelW, h: bw,
                   tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            // Left
            addQuad(to: &bv, x: offsetX, y: offsetY + bw, w: bw, h: cellPixelH - 2 * bw,
                   tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            // Right
            addQuad(to: &bv, x: offsetX + cellPixelW - bw, y: offsetY + bw, w: bw, h: cellPixelH - 2 * bw,
                   tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            if let buf = makeTemporaryBuffer(vertices: bv) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                      vertexCount: bv.count / floatsPerVertex)
            }
        }
    }
}

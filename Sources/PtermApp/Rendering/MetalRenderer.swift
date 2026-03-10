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
///
/// Supports Retina (HiDPI) rendering.
final class MetalRenderer {
    /// Metal device
    let device: MTLDevice

    /// Command queue
    private let commandQueue: MTLCommandQueue

    /// Render pipeline for cell backgrounds
    private var bgPipeline: MTLRenderPipelineState?

    /// Render pipeline for glyphs
    private var glyphPipeline: MTLRenderPipelineState?

    /// Render pipeline for cursor
    private var cursorPipeline: MTLRenderPipelineState?

    /// Glyph atlas
    let glyphAtlas: GlyphAtlas

    /// Sampler state for glyph texture
    private var sampler: MTLSamplerState?

    /// Vertex data for current frame
    private var bgVertices: [Float] = []
    private var glyphVertices: [Float] = []
    private var cursorVertices: [Float] = []

    /// MTLBuffers for vertex data (avoids 4KB setVertexBytes limit)
    private var bgBuffer: MTLBuffer?
    private var glyphBuffer: MTLBuffer?
    private var cursorBuffer: MTLBuffer?

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

    /// Default font size (points)
    static let defaultFontSize: CGFloat = 13.0

    /// Minimum font size
    static let minFontSize: CGFloat = 8.0

    /// Maximum font size
    static let maxFontSize: CGFloat = 72.0

    /// Font size step per Cmd+/Cmd- press
    static let fontSizeStep: CGFloat = 1.0

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
    }

    private func setupSampler() {
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.mipFilter = .notMipmapped
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: desc)
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
    func render(model: TerminalModel, in view: MTKView) {
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
        uniforms.cursorOpacity = model.cursor.visible ? 1.0 : 0.0

        // Clear color: black background
        renderPassDescriptor.colorAttachments[0].clearColor =
            MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Build vertex data
        buildVertexData(model: model, scaleFactor: Float(view.window?.backingScaleFactor ?? 2.0))

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

        // 3. Draw cursor
        if !cursorVertices.isEmpty, let pipeline = cursorPipeline,
           let buf = updateVertexBuffer(&cursorBuffer, vertices: cursorVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: cursorVertices.count / floatsPerVertex)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Vertex Building

    private func buildVertexData(model: TerminalModel, scaleFactor: Float) {
        bgVertices.removeAll(keepingCapacity: true)
        glyphVertices.removeAll(keepingCapacity: true)
        cursorVertices.removeAll(keepingCapacity: true)

        let cellW = Float(glyphAtlas.cellWidth) * scaleFactor
        let cellH = Float(glyphAtlas.cellHeight) * scaleFactor

        for row in 0..<model.rows {
            for col in 0..<model.cols {
                let cell = model.grid.cell(at: row, col: col)

                // Skip continuation cells of wide characters
                if cell.isWideContinuation { continue }

                let x = Float(col) * cellW
                let y = Float(row) * cellH
                let w = cellW * Float(max(1, cell.width))
                let h = cellH

                // Resolve colors (handle inverse)
                var fgColor: (r: Float, g: Float, b: Float)
                var bgColor: (r: Float, g: Float, b: Float)

                if cell.attributes.inverse {
                    fgColor = cell.attributes.background.resolve(isForeground: false)
                    bgColor = cell.attributes.foreground.resolve(isForeground: true)
                } else {
                    fgColor = cell.attributes.foreground.resolve(isForeground: true)
                    bgColor = cell.attributes.background.resolve(isForeground: false)
                }

                // Background quad (skip if default black to save draw calls)
                if bgColor.r > 0.001 || bgColor.g > 0.001 || bgColor.b > 0.001 {
                    addQuad(to: &bgVertices, x: x, y: y, w: w, h: h,
                           tx: 0, ty: 0, tw: 0, th: 0,
                           fg: (bgColor.r, bgColor.g, bgColor.b, 1),
                           bg: (bgColor.r, bgColor.g, bgColor.b, 1))
                }

                // Glyph
                if cell.codepoint > 0x20, // Skip spaces
                   let glyph = glyphAtlas.glyphInfo(for: cell.codepoint),
                   glyph.pixelWidth > 0 {

                    let glyphX = x + Float(glyph.bearingX) * scaleFactor
                    let glyphY = y + (cellH - Float(glyphAtlas.baseline) * scaleFactor
                                      - Float(glyph.bearingY) * scaleFactor
                                      - Float(glyph.pixelHeight))
                    let glyphW = Float(glyph.pixelWidth)
                    let glyphH = Float(glyph.pixelHeight)

                    addQuad(to: &glyphVertices,
                           x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                           tx: glyph.textureX, ty: glyph.textureY,
                           tw: glyph.textureW, th: glyph.textureH,
                           fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                           bg: (0, 0, 0, 0))
                }
            }
        }

        // Cursor
        if model.cursor.visible {
            let cx = Float(model.cursor.col) * cellW
            let cy = Float(model.cursor.row) * cellH
            addQuad(to: &cursorVertices, x: cx, y: cy, w: cellW, h: cellH,
                   tx: 0, ty: 0, tw: 0, th: 0,
                   fg: (0.8, 0.8, 0.8, 1),
                   bg: (0.8, 0.8, 0.8, 1))
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
}

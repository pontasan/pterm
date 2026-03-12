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
    static let renderTargetPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb
    static let renderTargetColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    static func linearizeSRGBComponent(_ component: Float) -> Float {
        if component <= 0.04045 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }

    static func linearizeSRGBColor(
        r: Float,
        g: Float,
        b: Float,
        a: Float
    ) -> (r: Float, g: Float, b: Float, a: Float) {
        (
            linearizeSRGBComponent(r),
            linearizeSRGBComponent(g),
            linearizeSRGBComponent(b),
            a
        )
    }

    private static func snapToPixel(_ value: Float) -> Float {
        round(value)
    }

    struct TerminalAppearance {
        var defaultForeground: (r: Float, g: Float, b: Float)
        var defaultBackground: (r: Float, g: Float, b: Float, a: Float)

        static let `default` = TerminalAppearance(
            defaultForeground: (0.8, 0.8, 0.8),
            defaultBackground: (0.0, 0.0, 0.0, 1.0)
        )
    }

    /// Result of building vertex data for a single frame.
    struct VertexData {
        var bgVertices: [Float] = []
        var glyphVertices: [Float] = []
        var cursorVertices: [Float] = []
        var overlayVertices: [Float] = []
    }

    private struct SearchMatchSpan {
        let start: Int
        let end: Int
        let isCurrent: Bool
    }

    /// Metal device
    let device: MTLDevice

    /// Command queue (accessible for IntegratedView)
    let commandQueue: MTLCommandQueue

    /// Render pipeline for cell backgrounds
    private(set) var bgPipeline: MTLRenderPipelineState?

    /// Render pipeline for glyphs
    private(set) var glyphPipeline: MTLRenderPipelineState?
    private(set) var lowDPIGlyphPipeline: MTLRenderPipelineState?

    /// Render pipeline for cursor
    private(set) var cursorPipeline: MTLRenderPipelineState?

    /// Render pipeline for overlay (scrollbar, etc.)
    private(set) var overlayPipeline: MTLRenderPipelineState?

    /// Render pipeline for analytic circles
    private(set) var circlePipeline: MTLRenderPipelineState?

    /// Glyph atlas
    let glyphAtlas: GlyphAtlas
    var terminalAppearance: TerminalAppearance = .default

    /// Sampler state for glyph texture (nearest-neighbor for full-size)
    private var sampler: MTLSamplerState?

    /// Sampler state for thumbnails (linear filtering for scaled-down rendering)
    private var thumbnailSampler: MTLSamplerState?

    /// Public accessor for sampler (used by IntegratedView)
    var samplerState: MTLSamplerState? { sampler }
    var thumbnailSamplerState: MTLSamplerState? { thumbnailSampler }

    /// Per-view buffer set to avoid conflicts when multiple MTKViews share this renderer.
    final class ViewBufferSet {
        var bgBuffer: MTLBuffer?
        var glyphBuffer: MTLBuffer?
        var cursorBuffer: MTLBuffer?
        var overlayBuffer: MTLBuffer?
        var borderBuffer: MTLBuffer?
        var splitBgBuffer: MTLBuffer?
        var splitGlyphBuffer: MTLBuffer?
        var splitCursorBuffer: MTLBuffer?
        var splitOverlayBuffer: MTLBuffer?
        var splitBorderBuffer: MTLBuffer?
        var overviewPreOverlayBuffer: MTLBuffer?
        var overviewPostOverlayBuffer: MTLBuffer?
        var overviewTextGlyphBuffer: MTLBuffer?
        var overviewIconGlyphBuffer: MTLBuffer?
        var overviewCircleGlyphBuffer: MTLBuffer?
        var overviewThumbnailBgBuffer: MTLBuffer?
        var overviewThumbnailGlyphBuffer: MTLBuffer?
    }

    enum ViewBufferSlot {
        case overviewPreOverlay
        case overviewPostOverlay
        case overviewTextGlyph
        case overviewIconGlyph
        case overviewCircleGlyph
        case overviewThumbnailBg
        case overviewThumbnailGlyph
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

    func updateTerminalAppearance(_ appearance: TerminalAppearanceConfiguration) {
        terminalAppearance = TerminalAppearance(
            defaultForeground: (
                Float(appearance.foreground.red) / 255.0,
                Float(appearance.foreground.green) / 255.0,
                Float(appearance.foreground.blue) / 255.0
            ),
            defaultBackground: (
                Float(appearance.background.red) / 255.0,
                Float(appearance.background.green) / 255.0,
                Float(appearance.background.blue) / 255.0,
                Float(appearance.normalizedBackgroundOpacity)
            )
        )
    }

    var terminalClearColor: MTLClearColor {
        let background = terminalAppearance.defaultBackground
        let linear = Self.linearizeSRGBColor(
            r: background.r,
            g: background.g,
            b: background.b,
            a: background.a
        )
        return MTLClearColor(
            red: Double(linear.r),
            green: Double(linear.g),
            blue: Double(linear.b),
            alpha: Double(linear.a)
        )
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
            desc.colorAttachments[0].pixelFormat = Self.renderTargetPixelFormat
            bgPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        // Glyph pipeline (with alpha blending)
        if let glyphVertex = library.makeFunction(name: "glyph_vertex"),
           let glyphFragment = library.makeFunction(name: "glyph_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = glyphVertex
            desc.fragmentFunction = glyphFragment
            desc.colorAttachments[0].pixelFormat = Self.renderTargetPixelFormat
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            glyphPipeline = try? device.makeRenderPipelineState(descriptor: desc)

            if let lowDPIGlyphFragment = library.makeFunction(name: "lowdpi_glyph_fragment") {
                let lowDPIDesc = MTLRenderPipelineDescriptor()
                lowDPIDesc.vertexFunction = glyphVertex
                lowDPIDesc.fragmentFunction = lowDPIGlyphFragment
                lowDPIDesc.colorAttachments[0].pixelFormat = Self.renderTargetPixelFormat
                lowDPIDesc.colorAttachments[0].isBlendingEnabled = true
                lowDPIDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                lowDPIDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                lowDPIDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
                lowDPIDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                lowDPIGlyphPipeline = try? device.makeRenderPipelineState(descriptor: lowDPIDesc)
            }
        }

        // Cursor pipeline (with alpha blending)
        if let cursorVertex = library.makeFunction(name: "bg_vertex"),
           let cursorFragment = library.makeFunction(name: "cursor_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = cursorVertex
            desc.fragmentFunction = cursorFragment
            desc.colorAttachments[0].pixelFormat = Self.renderTargetPixelFormat
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
            desc.colorAttachments[0].pixelFormat = Self.renderTargetPixelFormat
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            overlayPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        // Analytic circle pipeline (alpha blending, coverage from UV distance)
        if let circleVertex = library.makeFunction(name: "glyph_vertex"),
           let circleFragment = library.makeFunction(name: "circle_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = circleVertex
            desc.fragmentFunction = circleFragment
            desc.colorAttachments[0].pixelFormat = Self.renderTargetPixelFormat
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            circlePipeline = try? device.makeRenderPipelineState(descriptor: desc)
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

    private func glyphSamplerForCurrentOutput() -> MTLSamplerState? {
        if glyphAtlas.scaleFactor <= 1.0 {
            return thumbnailSampler ?? sampler
        }
        return sampler
    }

    private func glyphPipelineForCurrentOutput() -> MTLRenderPipelineState? {
        if glyphAtlas.scaleFactor <= 1.0 {
            return lowDPIGlyphPipeline ?? glyphPipeline
        }
        return glyphPipeline
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

        // Clear color: terminal background
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = terminalClearColor

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
        if !vd.glyphVertices.isEmpty, let pipeline = glyphPipelineForCurrentOutput(),
           let atlas = glyphAtlas.texture,
           let buf = updateVertexBuffer(&bs.glyphBuffer, vertices: vd.glyphVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.setFragmentSamplerState(glyphSamplerForCurrentOutput(), index: 0)
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
        let lineThickness = max(1.0, scaleFactor)
        let cursorThickness = max(1.0, scaleFactor * 2.0)

        let viewRows = model.rows
        let viewCols = model.cols
        let sbCount = scrollback.rowCount
        let approximateCellCount = max(1, viewRows * viewCols)
        vd.bgVertices.reserveCapacity(approximateCellCount * 18)
        vd.glyphVertices.reserveCapacity(approximateCellCount * 24)
        vd.cursorVertices.reserveCapacity(72)
        vd.overlayVertices.reserveCapacity(approximateCellCount * 12)

        // Pre-fetch scrollback rows that are visible in the viewport.
        // Each row is fetched once and reused for all columns.
        var scrollbackRows = Array<[Cell]?>(repeating: nil, count: viewRows)
        if scrollOffset > 0 {
            let firstAbsolute = max(0, sbCount - scrollOffset)
            for viewRow in 0..<viewRows {
                let absRow = firstAbsolute + viewRow
                if absRow >= 0 && absRow < sbCount {
                    scrollbackRows[viewRow] = scrollback.getRow(at: absRow)
                }
            }
        }

        let firstAbsolute = scrollOffset > 0 ? max(0, sbCount - scrollOffset) : sbCount

        // Build per-visible-row search match lists once so we can walk them linearly.
        var searchMatchesByVisibleRow = Array<[SearchMatchSpan]>(repeating: [], count: viewRows)
        if let sh = searchHighlight {
            for (i, match) in sh.matches.enumerated() {
                let visibleRow = match.absoluteRow - firstAbsolute
                guard visibleRow >= 0, visibleRow < viewRows else { continue }
                searchMatchesByVisibleRow[visibleRow].append(
                    SearchMatchSpan(start: match.startCol, end: match.endCol, isCurrent: sh.currentIndex == i)
                )
            }
        }

        for row in 0..<viewRows {
            let absoluteRow = firstAbsolute + row
            let isScrollbackRow = absoluteRow < sbCount
            let scrollbackRow = isScrollbackRow ? scrollbackRows[row] : nil
            let gridRow = isScrollbackRow ? -1 : absoluteRow - sbCount

            let rowMatches = searchMatchesByVisibleRow[row]
            var currentMatchIndex = 0
            let selectedColumnRange: ClosedRange<Int>? = {
                guard let selection else { return nil }
                let start = selection.start
                let end = selection.end
                switch selection.mode {
                case .normal:
                    guard row >= start.row, row <= end.row else { return nil }
                    if start.row == end.row {
                        return start.col...end.col
                    }
                    if row == start.row {
                        return start.col...Int.max
                    }
                    if row == end.row {
                        return Int.min...end.col
                    }
                    return Int.min...Int.max
                case .rectangular:
                    guard row >= start.row, row <= end.row else { return nil }
                    return start.col...end.col
                }
            }()

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
                var bgColor: (r: Float, g: Float, b: Float, a: Float)

                let isSelected = selectedColumnRange?.contains(col) ?? false
                let usesDefaultBackground = cell.attributes.background.isDefaultColor

                var searchMatchType: Int = 0 // 0=none, 1=match, 2=current match
                while currentMatchIndex < rowMatches.count && col > rowMatches[currentMatchIndex].end {
                    currentMatchIndex += 1
                }
                if currentMatchIndex < rowMatches.count {
                    let match = rowMatches[currentMatchIndex]
                    if col >= match.start && col <= match.end {
                        searchMatchType = match.isCurrent ? 2 : 1
                    }
                }

                if cell.attributes.inverse != isSelected {
                    // Inverse XOR selected: swap fg/bg
                    fgColor = resolveBackgroundColorAsForeground(cell.attributes.background)
                    bgColor = resolveForegroundColorAsBackground(cell.attributes.foreground)
                } else {
                    fgColor = resolveForegroundColor(for: cell)
                    bgColor = resolveBackgroundColor(cell.attributes.background)
                }

                // Apply search match highlight
                if searchMatchType == 2 {
                    // Current match: bright orange background, dark foreground
                    bgColor = (0.90, 0.60, 0.10, 1.0)
                    fgColor = (0.0, 0.0, 0.0)
                } else if searchMatchType == 1 {
                    // Other matches: dim yellow background
                    bgColor = (0.55, 0.45, 0.10, 1.0)
                    fgColor = (0.0, 0.0, 0.0)
                }

                if cell.attributes.hidden {
                    fgColor = (bgColor.r, bgColor.g, bgColor.b)
                } else if cell.attributes.dim && searchMatchType == 0 {
                    fgColor = (fgColor.r * 0.66, fgColor.g * 0.66, fgColor.b * 0.66)
                }

                // Skip default-background quads in the common case: the render pass clear color
                // already fills the terminal with the configured default background.
                let needsBackgroundQuad =
                    isSelected ||
                    searchMatchType > 0 ||
                    (cell.attributes.inverse != isSelected) ||
                    !usesDefaultBackground
                if needsBackgroundQuad {
                    addQuad(to: &vd.bgVertices, x: x, y: y, w: w, h: h,
                           tx: 0, ty: 0, tw: 0, th: 0,
                           fg: (bgColor.r, bgColor.g, bgColor.b, bgColor.a),
                           bg: (bgColor.r, bgColor.g, bgColor.b, bgColor.a))
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

                    let rawGlyphX: Float
                    if cell.width == 1 {
                        rawGlyphX = x + glyph.cellOffsetX
                    } else {
                        let glyphAdvance = max(0, glyph.advance * scaleFactor)
                        let centeredOffset = max(0, (w - glyphAdvance) * 0.5)
                        rawGlyphX = x + centeredOffset + Float(glyph.bearingX) * scaleFactor
                    }
                    // Position glyph so its baseline (at baselineOffset pixels from
                    // the bitmap top) aligns with the cell's baseline screen position.
                    let baselineScreenY = y + cellH - Float(glyphAtlas.baseline) * scaleFactor
                    let rawGlyphY = baselineScreenY - glyph.baselineOffset
                    let shouldSnapGlyphPosition = !glyphAtlas.usesOversampledRasterizationForCurrentDisplay
                    let glyphX = shouldSnapGlyphPosition ? Self.snapToPixel(rawGlyphX) : rawGlyphX
                    let glyphY = shouldSnapGlyphPosition ? Self.snapToPixel(rawGlyphY) : rawGlyphY
                    let glyphW = Float(glyph.pixelWidth)
                    let glyphH = Float(glyph.pixelHeight)

                    addQuad(to: &vd.glyphVertices,
                           x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                           tx: glyph.textureX, ty: glyph.textureY,
                           tw: glyph.textureW, th: glyph.textureH,
                           fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                           bg: (0, 0, 0, 0))

                    if cell.attributes.bold {
                        let boldOffset = max(1.0, ceil(scaleFactor * 0.5))
                        addQuad(to: &vd.glyphVertices,
                               x: glyphX + boldOffset, y: glyphY, w: glyphW, h: glyphH,
                               tx: glyph.textureX, ty: glyph.textureY,
                               tw: glyph.textureW, th: glyph.textureH,
                               fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                               bg: (0, 0, 0, 0))
                    }
                }

                if cell.attributes.underline {
                    let underlineY = y + h - lineThickness
                    addQuad(to: &vd.overlayVertices, x: x, y: underlineY, w: w, h: lineThickness,
                           tx: 0, ty: 0, tw: 0, th: 0,
                           fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                           bg: (fgColor.r, fgColor.g, fgColor.b, 1))
                }

                if cell.attributes.strikethrough {
                    let strikeY = y + (h * 0.5) - (lineThickness * 0.5)
                    addQuad(to: &vd.overlayVertices, x: x, y: strikeY, w: w, h: lineThickness,
                           tx: 0, ty: 0, tw: 0, th: 0,
                           fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                           bg: (fgColor.r, fgColor.g, fgColor.b, 1))
                }

                // URL hover underline
                if let link = linkUnderline,
                   row == link.row && col >= link.startCol && col <= link.endCol {
                    let underlineY = y + h - lineThickness
                    // Blue underline for link hover
                    addQuad(to: &vd.overlayVertices, x: x, y: underlineY, w: w, h: lineThickness,
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
                addQuad(to: &vd.cursorVertices, x: cx, y: cy + cellH - cursorThickness,
                       w: cellW, h: cursorThickness,
                       tx: 0, ty: 0, tw: 0, th: 0,
                       fg: cursorColor, bg: cursorColor)
            case .bar:
                addQuad(to: &vd.cursorVertices, x: cx, y: cy,
                       w: cursorThickness, h: cellH,
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

        return resolveForegroundColor(cell.attributes.foreground)
    }

    private func resolveForegroundColor(_ color: TerminalColor) -> (r: Float, g: Float, b: Float) {
        switch color {
        case .default:
            return terminalAppearance.defaultForeground
        default:
            return color.resolve(isForeground: true)
        }
    }

    private func resolveBackgroundColor(_ color: TerminalColor) -> (r: Float, g: Float, b: Float, a: Float) {
        switch color {
        case .default:
            return terminalAppearance.defaultBackground
        default:
            let resolved = color.resolve(isForeground: false)
            return (resolved.r, resolved.g, resolved.b, 1.0)
        }
    }

    private func resolveBackgroundColorAsForeground(_ color: TerminalColor) -> (r: Float, g: Float, b: Float) {
        let background = resolveBackgroundColor(color)
        return (background.r, background.g, background.b)
    }

    private func resolveForegroundColorAsBackground(_ color: TerminalColor) -> (r: Float, g: Float, b: Float, a: Float) {
        let foreground = resolveForegroundColor(color)
        return (foreground.r, foreground.g, foreground.b, 1.0)
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
        let linearFG = Self.linearizeSRGBColor(r: fg.r, g: fg.g, b: fg.b, a: fg.a)
        let linearBG = Self.linearizeSRGBColor(r: bg.r, g: bg.g, b: bg.b, a: bg.a)
        // Triangle 1: top-left, top-right, bottom-left
        appendVertex(to: &vertices, x: x, y: y, tx: tx, ty: ty, fg: linearFG, bg: linearBG)
        appendVertex(to: &vertices, x: x + w, y: y, tx: tx + tw, ty: ty, fg: linearFG, bg: linearBG)
        appendVertex(to: &vertices, x: x, y: y + h, tx: tx, ty: ty + th, fg: linearFG, bg: linearBG)
        // Triangle 2: top-right, bottom-right, bottom-left
        appendVertex(to: &vertices, x: x + w, y: y, tx: tx + tw, ty: ty, fg: linearFG, bg: linearBG)
        appendVertex(to: &vertices, x: x + w, y: y + h, tx: tx + tw, ty: ty + th, fg: linearFG, bg: linearBG)
        appendVertex(to: &vertices, x: x, y: y + h, tx: tx, ty: ty + th, fg: linearFG, bg: linearBG)
    }

    private func appendVertex(
        to vertices: inout [Float],
        x: Float,
        y: Float,
        tx: Float,
        ty: Float,
        fg: (r: Float, g: Float, b: Float, a: Float),
        bg: (r: Float, g: Float, b: Float, a: Float)
    ) {
        vertices.append(x)
        vertices.append(y)
        vertices.append(tx)
        vertices.append(ty)
        vertices.append(fg.r)
        vertices.append(fg.g)
        vertices.append(fg.b)
        vertices.append(fg.a)
        vertices.append(bg.r)
        vertices.append(bg.g)
        vertices.append(bg.b)
        vertices.append(bg.a)
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

    func reusableBuffer(for view: MTKView, slot: ViewBufferSlot, vertices: [Float]) -> MTLBuffer? {
        let bs = bufferSet(for: view)
        switch slot {
        case .overviewPreOverlay:
            return updateVertexBuffer(&bs.overviewPreOverlayBuffer, vertices: vertices)
        case .overviewPostOverlay:
            return updateVertexBuffer(&bs.overviewPostOverlayBuffer, vertices: vertices)
        case .overviewTextGlyph:
            return updateVertexBuffer(&bs.overviewTextGlyphBuffer, vertices: vertices)
        case .overviewIconGlyph:
            return updateVertexBuffer(&bs.overviewIconGlyphBuffer, vertices: vertices)
        case .overviewCircleGlyph:
            return updateVertexBuffer(&bs.overviewCircleGlyphBuffer, vertices: vertices)
        case .overviewThumbnailBg:
            return updateVertexBuffer(&bs.overviewThumbnailBgBuffer, vertices: vertices)
        case .overviewThumbnailGlyph:
            return updateVertexBuffer(&bs.overviewThumbnailGlyphBuffer, vertices: vertices)
        }
    }

    private func updateShiftedVertexBuffer(
        _ buffer: inout MTLBuffer?,
        source: [Float],
        offsetX: Float,
        offsetY: Float
    ) -> MTLBuffer? {
        let byteCount = source.count * MemoryLayout<Float>.size
        guard byteCount > 0 else { return nil }

        if buffer == nil || buffer!.length < byteCount {
            let allocSize = byteCount + byteCount / 2
            buffer = device.makeBuffer(length: allocSize, options: .storageModeShared)
        }

        guard let buffer else { return nil }
        let pointer = buffer.contents().bindMemory(to: Float.self, capacity: source.count)
        source.withUnsafeBufferPointer { sourcePointer in
            let stride = floatsPerVertex
            var index = 0
            while index < sourcePointer.count {
                pointer[index] = sourcePointer[index] + offsetX
                pointer[index + 1] = sourcePointer[index + 1] + offsetY
                for component in 2..<stride {
                    pointer[index + component] = sourcePointer[index + component]
                }
                index += stride
            }
        }
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
        appendThumbnailVertexData(
            model: model,
            scrollback: scrollback,
            scrollOffset: scrollOffset,
            thumbnailRect: thumbnailRect,
            scaleFactor: scaleFactor,
            bgVertices: &thumbBgVertices,
            glyphVertices: &thumbGlyphVertices
        )

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

    func appendThumbnailVertexData(model: TerminalModel, scrollback: ScrollbackBuffer,
                                   scrollOffset: Int, thumbnailRect: NSRect,
                                   scaleFactor: Float,
                                   bgVertices: inout [Float],
                                   glyphVertices: inout [Float]) {
        let cellW = Float(glyphAtlas.cellWidth) * scaleFactor
        let cellH = Float(glyphAtlas.cellHeight) * scaleFactor
        let padX = Float(gridPadding) * scaleFactor
        let padY = Float(gridPadding) * scaleFactor

        let viewRows = model.rows
        let viewCols = model.cols
        let approximateCellCount = max(1, viewRows * viewCols)
        bgVertices.reserveCapacity(bgVertices.count + approximateCellCount * 18)
        glyphVertices.reserveCapacity(glyphVertices.count + approximateCellCount * 24)

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
        var scrollbackRows = Array<[Cell]?>(repeating: nil, count: viewRows)
        if scrollOffset > 0 {
            let firstAbsolute = max(0, sbCount - scrollOffset)
            for viewRow in 0..<viewRows {
                let absRow = firstAbsolute + viewRow
                if absRow >= 0 && absRow < sbCount {
                    scrollbackRows[viewRow] = scrollback.getRow(at: absRow)
                }
            }
        }

        let firstAbsolute = scrollOffset > 0 ? max(0, sbCount - scrollOffset) : sbCount

        for row in 0..<viewRows {
            let absoluteRow = firstAbsolute + row
            let isScrollbackRow = absoluteRow < sbCount
            let scrollbackRow = isScrollbackRow ? scrollbackRows[row] : nil
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
                var bgColor: (r: Float, g: Float, b: Float, a: Float)
                let usesDefaultBackground = cell.attributes.background.isDefaultColor

                if cell.attributes.inverse {
                    fgColor = resolveBackgroundColorAsForeground(cell.attributes.background)
                    bgColor = resolveForegroundColorAsBackground(cell.attributes.foreground)
                } else {
                    fgColor = resolveForegroundColor(cell.attributes.foreground)
                    bgColor = resolveBackgroundColor(cell.attributes.background)
                }

                let needsBackgroundQuad = cell.attributes.inverse || !usesDefaultBackground
                if needsBackgroundQuad {
                    addQuad(to: &bgVertices, x: x, y: y, w: w, h: h,
                           tx: 0, ty: 0, tw: 0, th: 0,
                           fg: (bgColor.r, bgColor.g, bgColor.b, bgColor.a),
                           bg: (bgColor.r, bgColor.g, bgColor.b, bgColor.a))
                }

                // Glyph
                if cell.codepoint > 0x20,
                   let glyph = glyphAtlas.glyphInfo(for: cell.codepoint),
                   glyph.pixelWidth > 0 {

                    let glyphFullX = fullX + glyph.cellOffsetX
                    let baselineScreenY = fullY + fullH - Float(glyphAtlas.baseline) * scaleFactor
                    let glyphFullY = baselineScreenY - glyph.baselineOffset
                    let glyphFullW = Float(glyph.pixelWidth)
                    let glyphFullH = Float(glyph.pixelHeight)

                    // Transform glyph to thumbnail space
                    let gx = offsetX + glyphFullX * thumbScale
                    let gy = offsetY + glyphFullY * thumbScale
                    let gw = glyphFullW * thumbScale
                    let gh = glyphFullH * thumbScale

                    addQuad(to: &glyphVertices,
                           x: gx, y: gy, w: gw, h: gh,
                           tx: glyph.textureX, ty: glyph.textureY,
                           tw: glyph.textureW, th: glyph.textureH,
                           fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                           bg: (0, 0, 0, 0))
                }
            }
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
                         scaleFactor: Float,
                         in view: MTKView) {
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

        // 1. Backgrounds
        if !vd.bgVertices.isEmpty, let pipeline = bgPipeline {
            let shifted = shiftedVertices(vd.bgVertices, offsetX: offsetX, offsetY: offsetY)
            if let buf = makeTemporaryBuffer(vertices: shifted) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                      vertexCount: vd.bgVertices.count / floatsPerVertex)
            }
        }

        // 2. Glyphs
        if !vd.glyphVertices.isEmpty, let pipeline = glyphPipelineForCurrentOutput(),
           let atlas = glyphAtlas.texture {
            let shifted = shiftedVertices(vd.glyphVertices, offsetX: offsetX, offsetY: offsetY)
            if let buf = makeTemporaryBuffer(vertices: shifted) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.setFragmentTexture(atlas, index: 0)
                encoder.setFragmentSamplerState(glyphSamplerForCurrentOutput(), index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                      vertexCount: vd.glyphVertices.count / floatsPerVertex)
            }
        }

        // 3. Cursor
        if !vd.cursorVertices.isEmpty, let pipeline = cursorPipeline {
            let shifted = shiftedVertices(vd.cursorVertices, offsetX: offsetX, offsetY: offsetY)
            if let buf = makeTemporaryBuffer(vertices: shifted) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                      vertexCount: vd.cursorVertices.count / floatsPerVertex)
            }
        }

        // 4. Overlay (underline, strikethrough, block elements)
        if !vd.overlayVertices.isEmpty, let pipeline = overlayPipeline {
            let shifted = shiftedVertices(vd.overlayVertices, offsetX: offsetX, offsetY: offsetY)
            if let buf = makeTemporaryBuffer(vertices: shifted) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                      vertexCount: vd.overlayVertices.count / floatsPerVertex)
            }
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

    private func shiftedVertices(_ source: [Float], offsetX: Float, offsetY: Float) -> [Float] {
        guard !source.isEmpty else { return [] }
        var shifted: [Float] = []
        shifted.reserveCapacity(source.count)
        source.withUnsafeBufferPointer { sourcePointer in
            let stride = floatsPerVertex
            var index = 0
            while index < sourcePointer.count {
                shifted.append(sourcePointer[index] + offsetX)
                shifted.append(sourcePointer[index + 1] + offsetY)
                for component in 2..<stride {
                    shifted.append(sourcePointer[index + component])
                }
                index += stride
            }
        }
        return shifted
    }
}

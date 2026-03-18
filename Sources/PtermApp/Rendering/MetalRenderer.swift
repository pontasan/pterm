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

    static func wideGlyphOffsetX(
        _ glyph: GlyphAtlas.GlyphInfo,
        spanWidth: Float,
        singleCellWidth: Float
    ) -> Float {
        glyph.cellOffsetX + ((spanWidth - singleCellWidth) * 0.5)
    }

    private static func shouldAttemptColorEmoji(for cell: Cell) -> Bool {
        cell.mayUseColorEmojiPresentation()
    }

    @inline(__always)
    private static func couldBeRenderedAsBlockElement(_ codepoint: UInt32) -> Bool {
        codepoint >= 0x2580 && codepoint <= 0x259F
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
    final class VertexData {
        struct InlineImageDraw {
            let ownerID: UUID
            let index: Int
            let vertices: [Float]
        }

        var bgVertices: [Float] = []
        var glyphVertices: [Float] = []
        var colorGlyphVertices: [Float] = []
        var inlineImageDraws: [InlineImageDraw] = []
        var cursorVertices: [Float] = []
        var overlayVertices: [Float] = []

        func reset(keepingCapacity: Bool = true) {
            bgVertices.removeAll(keepingCapacity: keepingCapacity)
            glyphVertices.removeAll(keepingCapacity: keepingCapacity)
            colorGlyphVertices.removeAll(keepingCapacity: keepingCapacity)
            inlineImageDraws.removeAll(keepingCapacity: keepingCapacity)
            cursorVertices.removeAll(keepingCapacity: keepingCapacity)
            overlayVertices.removeAll(keepingCapacity: keepingCapacity)
        }
    }

    struct SearchMatchSpan {
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
    private(set) var texturePipeline: MTLRenderPipelineState?

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
    private let textureLoader: MTKTextureLoader
    private struct InlineImageTextureKey: Hashable {
        let ownerID: UUID
        let index: Int
    }
    private struct InlineImageTextureEntry {
        let generation: UUID
        let texture: MTLTexture
    }
    private var inlineImageTextures: [InlineImageTextureKey: InlineImageTextureEntry] = [:]

    @inline(__always)
    private static func rowsContainInlineImages<S: Sequence>(_ rows: S) -> Bool
    where S.Element == TerminalController.RenderRowSnapshot {
        for row in rows {
            if row.cells.contains(where: \.hasInlineImage) {
                return true
            }
        }
        return false
    }

    /// Per-view buffer set to avoid conflicts when multiple MTKViews share this renderer.
    final class ViewBufferSet {
        var bgBuffer: MTLBuffer?
        var glyphBuffer: MTLBuffer?
        var colorGlyphBuffer: MTLBuffer?
        var cursorBuffer: MTLBuffer?
        var overlayBuffer: MTLBuffer?
        var borderBuffer: MTLBuffer?
        var splitBgBuffer: MTLBuffer?
        var splitGlyphBuffer: MTLBuffer?
        var splitColorGlyphBuffer: MTLBuffer?
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
        var overviewThumbnailSurfaceBuffer: MTLBuffer?
        let terminalVertexScratch = VertexData()
        var terminalScrollbackRowsScratch: [[Cell]] = []
        var terminalScrollbackRowHasData: [Bool] = []
        var terminalSearchMatchesScratch: [[SearchMatchSpan]] = []
    }

    enum ViewBufferSlot {
        case overviewPreOverlay
        case overviewPostOverlay
        case overviewTextGlyph
        case overviewIconGlyph
        case overviewCircleGlyph
        case overviewThumbnailBg
        case overviewThumbnailGlyph
        case overviewThumbnailSurface
    }

    /// Border configuration for split-view rendering.
    struct BorderConfig {
        let color: (Float, Float, Float, Float)
        let width: Float
    }

    struct HeaderOverlayConfig {
        let text: String
        let backgroundColor: (Float, Float, Float, Float)
        let accentColor: (Float, Float, Float, Float)
        let textColor: (Float, Float, Float, Float)
        let usesBoldText: Bool
    }

    /// Keyed by view's ObjectIdentifier to give each MTKView its own buffers.
    private var viewBuffers: [ObjectIdentifier: ViewBufferSet] = [:]

    var activeViewBufferCount: Int {
        viewBuffers.count
    }

    func bufferLength(for view: MTKView, slot: ViewBufferSlot) -> Int? {
        let bs = viewBuffers[ObjectIdentifier(view)]
        switch slot {
        case .overviewPreOverlay:
            return bs?.overviewPreOverlayBuffer?.length
        case .overviewPostOverlay:
            return bs?.overviewPostOverlayBuffer?.length
        case .overviewTextGlyph:
            return bs?.overviewTextGlyphBuffer?.length
        case .overviewIconGlyph:
            return bs?.overviewIconGlyphBuffer?.length
        case .overviewCircleGlyph:
            return bs?.overviewCircleGlyphBuffer?.length
        case .overviewThumbnailBg:
            return bs?.overviewThumbnailBgBuffer?.length
        case .overviewThumbnailGlyph:
            return bs?.overviewThumbnailGlyphBuffer?.length
        case .overviewThumbnailSurface:
            return bs?.overviewThumbnailSurfaceBuffer?.length
        }
    }

    func terminalScrollbackScratchRowCapacity(for view: MTKView) -> Int {
        viewBuffers[ObjectIdentifier(view)]?.terminalScrollbackRowsScratch.count ?? 0
    }

    func terminalScrollbackScratchBufferedCellCount(for view: MTKView) -> Int {
        guard let bufferSet = viewBuffers[ObjectIdentifier(view)] else { return 0 }
        return zip(bufferSet.terminalScrollbackRowsScratch, bufferSet.terminalScrollbackRowHasData)
            .reduce(into: 0) { partialResult, pair in
                if pair.1 {
                    partialResult += pair.0.count
                }
            }
    }

    func terminalSearchScratchRowCapacity(for view: MTKView) -> Int {
        viewBuffers[ObjectIdentifier(view)]?.terminalSearchMatchesScratch.count ?? 0
    }

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

    private func pruneEmptyBufferSet(for view: MTKView) {
        let key = ObjectIdentifier(view)
        guard let bufferSet = viewBuffers[key] else { return }
        let allBuffers: [MTLBuffer?] = [
            bufferSet.bgBuffer,
            bufferSet.glyphBuffer,
            bufferSet.colorGlyphBuffer,
            bufferSet.cursorBuffer,
            bufferSet.overlayBuffer,
            bufferSet.borderBuffer,
            bufferSet.splitBgBuffer,
            bufferSet.splitGlyphBuffer,
            bufferSet.splitColorGlyphBuffer,
            bufferSet.splitCursorBuffer,
            bufferSet.splitOverlayBuffer,
            bufferSet.splitBorderBuffer,
            bufferSet.overviewPreOverlayBuffer,
            bufferSet.overviewPostOverlayBuffer,
            bufferSet.overviewTextGlyphBuffer,
            bufferSet.overviewIconGlyphBuffer,
            bufferSet.overviewCircleGlyphBuffer,
            bufferSet.overviewThumbnailBgBuffer,
            bufferSet.overviewThumbnailGlyphBuffer,
            bufferSet.overviewThumbnailSurfaceBuffer,
        ]
        if allBuffers.allSatisfy({ $0 == nil }) {
            viewBuffers.removeValue(forKey: key)
        }
    }

    func releaseTerminalBuffers(for view: MTKView) {
        guard let bufferSet = viewBuffers[ObjectIdentifier(view)] else { return }
        bufferSet.bgBuffer = nil
        bufferSet.glyphBuffer = nil
        bufferSet.colorGlyphBuffer = nil
        bufferSet.cursorBuffer = nil
        bufferSet.overlayBuffer = nil
        bufferSet.borderBuffer = nil
        bufferSet.terminalVertexScratch.reset(keepingCapacity: false)
        bufferSet.terminalScrollbackRowsScratch.removeAll(keepingCapacity: false)
        bufferSet.terminalScrollbackRowHasData.removeAll(keepingCapacity: false)
        bufferSet.terminalSearchMatchesScratch.removeAll(keepingCapacity: false)
        pruneEmptyBufferSet(for: view)
    }

    func releaseSplitBuffers(for view: MTKView) {
        guard let bufferSet = viewBuffers[ObjectIdentifier(view)] else { return }
        bufferSet.splitBgBuffer = nil
        bufferSet.splitGlyphBuffer = nil
        bufferSet.splitColorGlyphBuffer = nil
        bufferSet.splitCursorBuffer = nil
        bufferSet.splitOverlayBuffer = nil
        bufferSet.splitBorderBuffer = nil
        bufferSet.terminalVertexScratch.reset(keepingCapacity: false)
        bufferSet.terminalScrollbackRowsScratch.removeAll(keepingCapacity: false)
        bufferSet.terminalScrollbackRowHasData.removeAll(keepingCapacity: false)
        bufferSet.terminalSearchMatchesScratch.removeAll(keepingCapacity: false)
        pruneEmptyBufferSet(for: view)
    }

    func releaseOverviewBuffers(for view: MTKView) {
        guard let bufferSet = viewBuffers[ObjectIdentifier(view)] else { return }
        bufferSet.overviewPreOverlayBuffer = nil
        bufferSet.overviewPostOverlayBuffer = nil
        bufferSet.overviewTextGlyphBuffer = nil
        bufferSet.overviewIconGlyphBuffer = nil
        bufferSet.overviewCircleGlyphBuffer = nil
        bufferSet.overviewThumbnailBgBuffer = nil
        bufferSet.overviewThumbnailGlyphBuffer = nil
        bufferSet.overviewThumbnailSurfaceBuffer = nil
        pruneEmptyBufferSet(for: view)
    }

    func hasTerminalBuffers(for view: MTKView) -> Bool {
        guard let bufferSet = viewBuffers[ObjectIdentifier(view)] else { return false }
        return [
            bufferSet.bgBuffer,
            bufferSet.glyphBuffer,
            bufferSet.colorGlyphBuffer,
            bufferSet.cursorBuffer,
            bufferSet.overlayBuffer,
            bufferSet.borderBuffer,
        ].contains(where: { $0 != nil })
    }

    func hasSplitBuffers(for view: MTKView) -> Bool {
        guard let bufferSet = viewBuffers[ObjectIdentifier(view)] else { return false }
        return [
            bufferSet.splitBgBuffer,
            bufferSet.splitGlyphBuffer,
            bufferSet.splitColorGlyphBuffer,
            bufferSet.splitCursorBuffer,
            bufferSet.splitOverlayBuffer,
            bufferSet.splitBorderBuffer,
        ].contains(where: { $0 != nil })
    }

    func hasOverviewBuffers(for view: MTKView) -> Bool {
        guard let bufferSet = viewBuffers[ObjectIdentifier(view)] else { return false }
        return [
            bufferSet.overviewPreOverlayBuffer,
            bufferSet.overviewPostOverlayBuffer,
            bufferSet.overviewTextGlyphBuffer,
            bufferSet.overviewIconGlyphBuffer,
            bufferSet.overviewCircleGlyphBuffer,
            bufferSet.overviewThumbnailBgBuffer,
            bufferSet.overviewThumbnailGlyphBuffer,
            bufferSet.overviewThumbnailSurfaceBuffer,
        ].contains(where: { $0 != nil })
    }

    /// Animation start time
    private let startTime: CFTimeInterval = CACurrentMediaTime()

    /// Viewport size
    var viewportSize: SIMD2<Float> = .zero

    struct MetalUniforms {
        var viewportSize: SIMD2<Float> = .zero
        var positionOffset: SIMD2<Float> = .zero
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
    private let floatsPerQuad = 72

    init?(scaleFactor: CGFloat = 2.0) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return nil
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = queue
        self.textureLoader = MTKTextureLoader(device: device)

        let initialAtlasDimension = device.hasUnifiedMemory ? 2048 : 256
        let maxAtlasDimension = device.hasUnifiedMemory ? 4096 : 2048
        self.glyphAtlas = GlyphAtlas(
            device: device,
            fontSize: MetalRenderer.defaultFontSize,
            scaleFactor: scaleFactor,
            initialAtlasDimension: initialAtlasDimension,
            maxAtlasDimension: maxAtlasDimension,
            prerasterizeASCII: true
        )

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

    @discardableResult
    func compactIdleGlyphAtlas(maximumInactiveGenerations: UInt64 = 4096) -> Bool {
        glyphAtlas.compactRetainingRecentlyUsedGlyphs(
            maximumInactiveGenerations: maximumInactiveGenerations
        )
    }

    func releaseInlineImageTextures(ownerID: UUID) {
        inlineImageTextures.keys
            .filter { $0.ownerID == ownerID }
            .forEach { inlineImageTextures.removeValue(forKey: $0) }
    }

    func releaseInlineImageTextures(ownerID: UUID, retaining liveIndices: Set<Int>) {
        inlineImageTextures.keys
            .filter { $0.ownerID == ownerID && !liveIndices.contains($0.index) }
            .forEach { inlineImageTextures.removeValue(forKey: $0) }
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

        if let textureVertex = library.makeFunction(name: "glyph_vertex"),
           let textureFragment = library.makeFunction(name: "texture_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = textureVertex
            desc.fragmentFunction = textureFragment
            desc.colorAttachments[0].pixelFormat = Self.renderTargetPixelFormat
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            texturePipeline = try? device.makeRenderPipelineState(descriptor: desc)
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
        guard byteCount > 0 else {
            buffer = nil
            return nil
        }

        if shouldReallocateBuffer(buffer, requiredByteCount: byteCount) {
            let allocSize = normalizedReusableBufferSize(requiredByteCount: byteCount)
            buffer = device.makeBuffer(length: allocSize, options: .storageModeShared)
        }

        buffer?.contents().copyMemory(from: vertices, byteCount: byteCount)
        return buffer
    }

    private func normalizedReusableBufferSize(requiredByteCount: Int) -> Int {
        let minimumSize = 4 * 1024
        let alignment = 4 * 1024
        let headroom = min(max(requiredByteCount / 8, 1024), 64 * 1024)
        let target = max(requiredByteCount + headroom, minimumSize)
        let remainder = target % alignment
        if remainder == 0 { return target }
        return target + (alignment - remainder)
    }

    private func shouldReallocateBuffer(_ buffer: MTLBuffer?, requiredByteCount: Int) -> Bool {
        guard let buffer else { return true }
        if buffer.length < requiredByteCount { return true }
        // If the existing shared buffer is vastly larger than the current frame
        // payload, drop it so short-lived peaks do not become permanent RSS.
        let shrinkThreshold = max(normalizedReusableBufferSize(requiredByteCount: requiredByteCount) * 2, 32 * 1024)
        return buffer.length > shrinkThreshold
    }

    // MARK: - Rendering

    private func drawMonochromeGlyphVertices(
        _ vertices: [Float],
        encoder: MTLRenderCommandEncoder,
        uniforms: inout MetalUniforms,
        buffer: MTLBuffer?
    ) {
        guard !vertices.isEmpty,
              let pipeline = glyphPipelineForCurrentOutput(),
              let atlas = glyphAtlas.texture,
              let buffer else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.setFragmentSamplerState(glyphSamplerForCurrentOutput(), index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / floatsPerVertex)
    }

    private func drawColorGlyphVertices(
        _ vertices: [Float],
        encoder: MTLRenderCommandEncoder,
        uniforms: inout MetalUniforms,
        buffer: MTLBuffer?
    ) {
        guard !vertices.isEmpty,
              let pipeline = texturePipeline,
              let atlas = glyphAtlas.colorTexture,
              let buffer else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.setFragmentSamplerState(glyphSamplerForCurrentOutput(), index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / floatsPerVertex)
    }

    private func texture(
        for registeredImage: PastedImageRegistry.RegisteredImage,
        ownerID: UUID,
        index: Int
    ) -> MTLTexture? {
        let key = InlineImageTextureKey(ownerID: ownerID, index: index)
        if let cached = inlineImageTextures[key], cached.generation == registeredImage.generation {
            return cached.texture
        }
        if let texture = rawTexture(for: registeredImage) {
            inlineImageTextures[key] = InlineImageTextureEntry(
                generation: registeredImage.generation,
                texture: texture
            )
            return texture
        }
        if let imageData = registeredImage.rawPixelData,
           let imageFormat = registeredImage.rawPixelFormat,
           imageFormat == .png || imageFormat == .jpeg || imageFormat == .gif || imageFormat == .webp {
            let options: [MTKTextureLoader.Option: Any] = [
                .SRGB: true,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
            ]
            if let texture = try? textureLoader.newTexture(data: imageData, options: options) {
                inlineImageTextures[key] = InlineImageTextureEntry(
                    generation: registeredImage.generation,
                    texture: texture
                )
                return texture
            }
        }
        guard let cgImage = TerminalInlineImageSupport.cgImage(for: registeredImage) else {
            inlineImageTextures.removeValue(forKey: key)
            return nil
        }
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: true,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
        ]
        guard let texture = try? textureLoader.newTexture(cgImage: cgImage, options: options) else {
            return nil
        }
        inlineImageTextures[key] = InlineImageTextureEntry(
            generation: registeredImage.generation,
            texture: texture
        )
        return texture
    }

    private func rawTexture(for registeredImage: PastedImageRegistry.RegisteredImage) -> MTLTexture? {
        guard let rawPixelFormat = registeredImage.rawPixelFormat,
              let pixelWidth = registeredImage.pixelWidth,
              let pixelHeight = registeredImage.pixelHeight,
              pixelWidth > 0,
              pixelHeight > 0 else {
            return nil
        }
        let rawPixelData = registeredImage.rawPixelData ?? PastedImageRegistry.mappedBlobData(for: registeredImage)
        guard let rawPixelData else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let region = MTLRegionMake2D(0, 0, pixelWidth, pixelHeight)
        switch rawPixelFormat {
        case .rawRGBA:
            rawPixelData.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                texture.replace(
                    region: region,
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: pixelWidth * 4
                )
            }
        case .rawRGB:
            var rgba = Data(count: pixelWidth * pixelHeight * 4)
            rgba.withUnsafeMutableBytes { destinationBuffer in
                rawPixelData.withUnsafeBytes { sourceBuffer in
                    guard let src = sourceBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let dst = destinationBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    var sourceIndex = 0
                    var destinationIndex = 0
                    while sourceIndex < rawPixelData.count {
                        dst[destinationIndex] = src[sourceIndex]
                        dst[destinationIndex + 1] = src[sourceIndex + 1]
                        dst[destinationIndex + 2] = src[sourceIndex + 2]
                        dst[destinationIndex + 3] = 0xFF
                        sourceIndex += 3
                        destinationIndex += 4
                    }
                }
            }
            rgba.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                texture.replace(
                    region: region,
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: pixelWidth * 4
                )
            }
        default:
            return nil
        }

        return texture
    }

    private func drawInlineImageDraws(
        _ imageDraws: [VertexData.InlineImageDraw],
        encoder: MTLRenderCommandEncoder,
        uniforms: inout MetalUniforms
    ) {
        guard !imageDraws.isEmpty,
              let pipeline = texturePipeline else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
        encoder.setFragmentSamplerState(thumbnailSampler ?? sampler, index: 0)
        for imageDraw in imageDraws {
            guard let registeredImage = PastedImageRegistry.shared.registeredImage(ownerID: imageDraw.ownerID, forPlaceholderIndex: imageDraw.index),
                  let texture = texture(for: registeredImage, ownerID: imageDraw.ownerID, index: imageDraw.index),
                  let buffer = makeTemporaryBuffer(vertices: imageDraw.vertices) else {
                continue
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: imageDraw.vertices.count / floatsPerVertex)
        }
    }

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

    struct TransientTextOverlay {
        let text: String
        let row: Int
        let col: Int
        let columnWidth: Int
        let cursorRow: Int?
        let cursorCol: Int?
        let masksGridGlyphs: Bool
        let verticalOffset: Float
        let alpha: Float
    }

    func render(model: TerminalModel, scrollback: ScrollbackBuffer,
                scrollOffset: Int, selection: TerminalSelection?,
                searchHighlight: SearchHighlight? = nil,
                linkUnderline: LinkUnderline? = nil,
                borderConfig: BorderConfig? = nil,
                headerOverlayConfig: HeaderOverlayConfig? = nil,
                transientTextOverlays: [TransientTextOverlay] = [],
                suppressCursorBlink: Bool = false,
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
            positionOffset: .zero,
            cursorOpacity: (scrollOffset == 0 && model.cursor.visible) ? 1.0 : 0.0,
            cursorBlink: (model.cursor.blinking && !suppressCursorBlink) ? 1.0 : 0.0,
            time: Float(CACurrentMediaTime() - startTime)
        )

        // Clear color: terminal background
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = terminalClearColor

        // Use per-view resources to avoid conflicts when multiple MTKViews share this renderer.
        let bs = bufferSet(for: view)

        // Build vertex data using the atlas's scale factor.
        let sf = Float(glyphAtlas.scaleFactor)
        let vd = buildVertexData(model: model, scrollback: scrollback, scrollOffset: scrollOffset,
                                 selection: selection, searchHighlight: searchHighlight,
                                 linkUnderline: linkUnderline, transientTextOverlays: transientTextOverlays,
                                 scaleFactor: sf,
                                 bufferSet: bs)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor) else {
            return
        }

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
        drawMonochromeGlyphVertices(
            vd.glyphVertices,
            encoder: encoder,
            uniforms: &uniforms,
            buffer: updateVertexBuffer(&bs.glyphBuffer, vertices: vd.glyphVertices)
        )
        drawColorGlyphVertices(
            vd.colorGlyphVertices,
            encoder: encoder,
            uniforms: &uniforms,
            buffer: updateVertexBuffer(&bs.colorGlyphBuffer, vertices: vd.colorGlyphVertices)
        )

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

        if let headerOverlayConfig, let overlayPipeline, let glyphPipeline = glyphPipelineForCurrentOutput(),
           let atlas = glyphAtlas.texture {
            let headerVertices = headerOverlayVertices(
                config: headerOverlayConfig,
                frame: CGRect(origin: .zero, size: CGSize(width: CGFloat(vp.x / sf), height: CGFloat(vp.y / sf))),
                scaleFactor: sf
            )
            if !headerVertices.overlay.isEmpty,
               let buf = makeTemporaryBuffer(vertices: headerVertices.overlay) {
                encoder.setRenderPipelineState(overlayPipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                      vertexCount: headerVertices.overlay.count / floatsPerVertex)
            }
            if !headerVertices.glyphs.isEmpty,
               let buf = makeTemporaryBuffer(vertices: headerVertices.glyphs) {
                encoder.setRenderPipelineState(glyphPipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.setFragmentTexture(atlas, index: 0)
                encoder.setFragmentSamplerState(glyphSamplerForCurrentOutput(), index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                      vertexCount: headerVertices.glyphs.count / floatsPerVertex)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func render(snapshot: TerminalController.RenderSnapshot,
                selection: TerminalSelection?,
                searchHighlight: SearchHighlight? = nil,
                linkUnderline: LinkUnderline? = nil,
                borderConfig: BorderConfig? = nil,
                headerOverlayConfig: HeaderOverlayConfig? = nil,
                transientTextOverlays: [TransientTextOverlay] = [],
                suppressCursorBlink: Bool = false,
                in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let drawableSize = view.drawableSize
        let vp = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        var uniforms = MetalUniforms(
            viewportSize: vp,
            positionOffset: .zero,
            cursorOpacity: (snapshot.scrollOffset == 0 && snapshot.cursor.visible) ? 1.0 : 0.0,
            cursorBlink: (snapshot.cursor.blinking && !suppressCursorBlink) ? 1.0 : 0.0,
            time: Float(CACurrentMediaTime() - startTime)
        )

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = terminalClearColor

        let bs = bufferSet(for: view)
        let sf = Float(glyphAtlas.scaleFactor)
        let vd = buildVertexData(
            snapshot: snapshot,
            selection: selection,
            searchHighlight: searchHighlight,
            linkUnderline: linkUnderline,
            transientTextOverlays: transientTextOverlays,
            scaleFactor: sf,
            bufferSet: bs
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor) else {
            return
        }

        if !vd.bgVertices.isEmpty, let pipeline = bgPipeline,
           let buf = updateVertexBuffer(&bs.bgBuffer, vertices: vd.bgVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: vd.bgVertices.count / floatsPerVertex)
        }

        drawMonochromeGlyphVertices(
            vd.glyphVertices,
            encoder: encoder,
            uniforms: &uniforms,
            buffer: updateVertexBuffer(&bs.glyphBuffer, vertices: vd.glyphVertices)
        )
        drawColorGlyphVertices(
            vd.colorGlyphVertices,
            encoder: encoder,
            uniforms: &uniforms,
            buffer: updateVertexBuffer(&bs.colorGlyphBuffer, vertices: vd.colorGlyphVertices)
        )
        drawInlineImageDraws(
            vd.inlineImageDraws,
            encoder: encoder,
            uniforms: &uniforms
        )

        if !vd.cursorVertices.isEmpty, let pipeline = cursorPipeline,
           let buf = updateVertexBuffer(&bs.cursorBuffer, vertices: vd.cursorVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: vd.cursorVertices.count / floatsPerVertex)
        }

        if !vd.overlayVertices.isEmpty, let pipeline = overlayPipeline,
           let buf = updateVertexBuffer(&bs.overlayBuffer, vertices: vd.overlayVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: vd.overlayVertices.count / floatsPerVertex)
        }

        if let border = borderConfig, let pipeline = overlayPipeline {
            var bv: [Float] = []
            let vw = vp.x
            let vh = vp.y
            let bw = border.width * Float(glyphAtlas.scaleFactor)
            let c = border.color
            addQuad(to: &bv, x: 0, y: 0, w: vw, h: bw, tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            addQuad(to: &bv, x: 0, y: vh - bw, w: vw, h: bw, tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            addQuad(to: &bv, x: 0, y: bw, w: bw, h: vh - 2 * bw, tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            addQuad(to: &bv, x: vw - bw, y: bw, w: bw, h: vh - 2 * bw, tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            if let buf = updateVertexBuffer(&bs.borderBuffer, vertices: bv) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: bv.count / floatsPerVertex)
            }
        }

        if let headerOverlayConfig, let overlayPipeline, let glyphPipeline = glyphPipelineForCurrentOutput(),
           let atlas = glyphAtlas.texture {
            let headerVertices = headerOverlayVertices(
                config: headerOverlayConfig,
                frame: CGRect(origin: .zero, size: CGSize(width: CGFloat(vp.x / sf), height: CGFloat(vp.y / sf))),
                scaleFactor: sf
            )
            if !headerVertices.overlay.isEmpty,
               let buf = makeTemporaryBuffer(vertices: headerVertices.overlay) {
                encoder.setRenderPipelineState(overlayPipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: headerVertices.overlay.count / floatsPerVertex)
            }
            if !headerVertices.glyphs.isEmpty,
               let buf = makeTemporaryBuffer(vertices: headerVertices.glyphs) {
                encoder.setRenderPipelineState(glyphPipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.setFragmentTexture(atlas, index: 0)
                encoder.setFragmentSamplerState(glyphSamplerForCurrentOutput(), index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: headerVertices.glyphs.count / floatsPerVertex)
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
                                  transientTextOverlays: [TransientTextOverlay] = [],
                                  scaleFactor: Float,
                                  bufferSet: ViewBufferSet) -> VertexData {
        let vd = bufferSet.terminalVertexScratch
        vd.reset()

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
        // Reserve close to worst-case visible geometry up front so hot redraw paths
        // don't repeatedly grow the backing arrays while streaming output.
        vd.bgVertices.reserveCapacity(approximateCellCount * floatsPerQuad)
        vd.glyphVertices.reserveCapacity(approximateCellCount * floatsPerQuad * 2)
        vd.colorGlyphVertices.reserveCapacity(approximateCellCount * floatsPerQuad)
        vd.cursorVertices.reserveCapacity(floatsPerQuad)
        vd.overlayVertices.reserveCapacity(approximateCellCount * floatsPerQuad * 2)

        // Pre-fetch scrollback rows that are visible in the viewport.
        // Each row is fetched once and reused for all columns.
        prepareTerminalScrollbackRowsScratch(in: bufferSet, rowCount: viewRows)
        if scrollOffset > 0 {
            let firstAbsolute = max(0, sbCount - scrollOffset)
            for viewRow in 0..<viewRows {
                let absRow = firstAbsolute + viewRow
                if absRow >= 0 && absRow < sbCount {
                    bufferSet.terminalScrollbackRowHasData[viewRow] = scrollback.getRow(
                        at: absRow,
                        into: &bufferSet.terminalScrollbackRowsScratch[viewRow]
                    )
                }
            }
        }

        let firstAbsolute = scrollOffset > 0 ? max(0, sbCount - scrollOffset) : sbCount
        var cachedGlyphs: [UInt32: GlyphAtlas.GlyphInfo] = [:]
        var missingGlyphs: Set<UInt32> = []

        @inline(__always)
        func glyphInfo(for codepoint: UInt32) -> GlyphAtlas.GlyphInfo? {
            if let cached = cachedGlyphs[codepoint] {
                return cached
            }
            if missingGlyphs.contains(codepoint) {
                return nil
            }
            if let glyph = glyphAtlas.glyphInfo(for: codepoint) {
                cachedGlyphs[codepoint] = glyph
                return glyph
            }
            missingGlyphs.insert(codepoint)
            return nil
        }

        @inline(__always)
        func glyphInfoForCell(_ cell: Cell) -> GlyphAtlas.GlyphInfo? {
            if cell.hasGraphemeTail {
                guard let key = cell.graphemeCacheKey() else { return nil }
                return glyphAtlas.glyphInfo(for: key)
            }
            return glyphInfo(for: cell.codepoint)
        }

        // Build per-visible-row search match lists once so we can walk them linearly.
        prepareTerminalSearchMatchesScratch(in: bufferSet, rowCount: viewRows)
        if let sh = searchHighlight {
            for (i, match) in sh.matches.enumerated() {
                let visibleRow = match.absoluteRow - firstAbsolute
                guard visibleRow >= 0, visibleRow < viewRows else { continue }
                bufferSet.terminalSearchMatchesScratch[visibleRow].append(
                    SearchMatchSpan(start: match.startCol, end: match.endCol, isCurrent: sh.currentIndex == i)
                )
            }
        }
        let hasSelection = selection != nil
        let hasTransientTextOverlays = !transientTextOverlays.isEmpty
        let hasLinkUnderline = linkUnderline != nil
        let canUseCommonTextCellFastPath = !hasSelection && !hasTransientTextOverlays && !hasLinkUnderline && !model.reverseVideoEnabled
        let defaultForeground = terminalAppearance.defaultForeground

        @inline(__always)
        func appendCommonDefaultRowGlyphs(
            cells: [Cell],
            row: Int
        ) -> Bool {
            guard !cells.isEmpty else { return true }
            let y = padY + Float(row) * cellH

            for (col, cell) in cells.enumerated() {
                if cell.hasInlineImage {
                    continue
                }
                if cell.isWideContinuation {
                    continue
                }
                if cell.attributes != .default {
                    return false
                }
                if cell.codepoint <= 0x20 {
                    continue
                }

                let x = padX + Float(col) * cellW
                let w = cellW * Float(max(1, cell.width))
                let h = cellH

                if Self.couldBeRenderedAsBlockElement(cell.codepoint) && renderBlockElementIfNeeded(
                    codepoint: cell.codepoint,
                    x: x, y: y, w: w, h: h,
                    color: defaultForeground,
                    vertices: &vd.overlayVertices
                ) {
                    continue
                }

                let colorGlyph: GlyphAtlas.GlyphInfo?
                if Self.shouldAttemptColorEmoji(for: cell) {
                    colorGlyph = cell.graphemeCacheKey().flatMap { glyphAtlas.colorGlyphInfo(for: $0) }
                } else {
                    colorGlyph = nil
                }
                guard let glyph = colorGlyph ?? glyphInfoForCell(cell), glyph.pixelWidth > 0 else {
                    continue
                }

                let rawGlyphX: Float
                if cell.width == 1 {
                    rawGlyphX = x + glyph.cellOffsetX
                } else {
                    rawGlyphX = x + Self.wideGlyphOffsetX(
                        glyph,
                        spanWidth: w,
                        singleCellWidth: cellW
                    )
                }
                let baselineScreenY = y + cellH - Float(glyphAtlas.baseline) * scaleFactor
                let rawGlyphY = baselineScreenY - glyph.baselineOffset
                let shouldSnapGlyphPosition = !glyphAtlas.usesOversampledRasterizationForCurrentDisplay
                let glyphX = shouldSnapGlyphPosition ? Self.snapToPixel(rawGlyphX) : rawGlyphX
                let glyphY = shouldSnapGlyphPosition ? Self.snapToPixel(rawGlyphY) : rawGlyphY
                let glyphW = Float(glyph.pixelWidth)
                let glyphH = Float(glyph.pixelHeight)

                if colorGlyph != nil {
                    addQuad(to: &vd.colorGlyphVertices,
                            x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                            tx: glyph.textureX, ty: glyph.textureY,
                            tw: glyph.textureW, th: glyph.textureH,
                            fg: (1, 1, 1, 1),
                            bg: (0, 0, 0, 0))
                } else {
                    addQuad(to: &vd.glyphVertices,
                            x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                            tx: glyph.textureX, ty: glyph.textureY,
                            tw: glyph.textureW, th: glyph.textureH,
                            fg: (defaultForeground.r, defaultForeground.g, defaultForeground.b, 1),
                            bg: (0, 0, 0, 0))
                }
            }

            return true
        }

        var hasVisibleInlineImages = false
        for row in 0..<viewRows where !hasVisibleInlineImages {
            if bufferSet.terminalScrollbackRowHasData[row],
               bufferSet.terminalScrollbackRowsScratch[row].contains(where: \.hasInlineImage) {
                hasVisibleInlineImages = true
                break
            }

            let absoluteRow = firstAbsolute + row
            guard absoluteRow >= sbCount else { continue }
            let gridRow = absoluteRow - sbCount
            for col in 0..<viewCols {
                if model.grid.cell(at: gridRow, col: col).hasInlineImage {
                    hasVisibleInlineImages = true
                    break
                }
            }
        }

        if hasVisibleInlineImages {
            var visibleRowsForImagePlacement: [TerminalController.RenderRowSnapshot] = []
            visibleRowsForImagePlacement.reserveCapacity(viewRows)
            for row in 0..<viewRows {
                let absoluteRow = firstAbsolute + row
                let isScrollbackRow = absoluteRow < sbCount
                if isScrollbackRow, bufferSet.terminalScrollbackRowHasData[row] {
                    visibleRowsForImagePlacement.append(
                        TerminalController.RenderRowSnapshot(
                            cells: bufferSet.terminalScrollbackRowsScratch[row],
                            lineAttribute: .singleWidth,
                            isWrapped: scrollback.isRowWrapped(at: absoluteRow)
                        )
                    )
                } else {
                    let gridRow = absoluteRow - sbCount
                    var cells: [Cell] = []
                    cells.reserveCapacity(viewCols)
                    for col in 0..<viewCols {
                        cells.append(model.grid.cell(at: gridRow, col: col))
                    }
                    visibleRowsForImagePlacement.append(
                        TerminalController.RenderRowSnapshot(
                            cells: cells,
                            lineAttribute: model.grid.lineAttribute(at: gridRow),
                            isWrapped: model.grid.isWrapped(gridRow)
                        )
                    )
                }
            }

            let imagePlacements = TerminalInlineImageSupport.detectPlacements(in: visibleRowsForImagePlacement)
            vd.inlineImageDraws.reserveCapacity(imagePlacements.count)
            for placement in imagePlacements {
                let x = padX + Float(placement.startCol) * cellW
                let y = padY + Float(placement.row) * cellH
                let w = Float(placement.endCol - placement.startCol + 1) * cellW
                let h = Float(max(placement.rowSpan, 1)) * cellH
                var vertices: [Float] = []
                vertices.reserveCapacity(floatsPerQuad)
                addQuad(
                    to: &vertices,
                    x: x,
                    y: y,
                    w: w,
                    h: h,
                    tx: 0,
                    ty: 0,
                    tw: 1,
                    th: 1,
                    fg: (1, 1, 1, 1),
                    bg: (0, 0, 0, 0)
                )
                guard let ownerID = placement.ownerID else { continue }
                vd.inlineImageDraws.append(.init(ownerID: ownerID, index: placement.index, vertices: vertices))
            }
        }

        for row in 0..<viewRows {
            let absoluteRow = firstAbsolute + row
            let isScrollbackRow = absoluteRow < sbCount
            let scrollbackRow: [Cell]? = isScrollbackRow && bufferSet.terminalScrollbackRowHasData[row]
                ? bufferSet.terminalScrollbackRowsScratch[row]
                : nil
            let gridRow = isScrollbackRow ? -1 : absoluteRow - sbCount

            let rowMatches = bufferSet.terminalSearchMatchesScratch[row]
            let rowHasMatches = !rowMatches.isEmpty
            var currentMatchIndex = 0
            let selectedColumnRange: ClosedRange<Int>? = {
                guard hasSelection, let selection else { return nil }
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

            let commonFastPathCells = scrollbackRow ?? Array(model.grid.rowCells(gridRow))
            if canUseCommonTextCellFastPath && !rowHasMatches &&
                appendCommonDefaultRowGlyphs(cells: commonFastPathCells, row: row) {
                continue
            }

            for col in 0..<viewCols {
                let transientTextOverlayCoversCell = hasTransientTextOverlays && transientTextOverlays.contains {
                    $0.masksGridGlyphs &&
                    row == $0.row &&
                    col >= $0.col &&
                    col < ($0.col + $0.columnWidth)
                }
                let cell: Cell
                if let sbRow = scrollbackRow {
                    cell = col < sbRow.count ? sbRow[col] : .empty
                } else {
                    cell = model.grid.cell(at: gridRow, col: col)
                }

                if cell.hasInlineImage {
                    continue
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

                let isSelected = hasSelection && (selectedColumnRange?.contains(col) ?? false)
                let usesDefaultBackground = cell.attributes.background.isDefaultColor

                var searchMatchType: Int = 0 // 0=none, 1=match, 2=current match
                if rowHasMatches {
                    while currentMatchIndex < rowMatches.count && col > rowMatches[currentMatchIndex].end {
                        currentMatchIndex += 1
                    }
                    if currentMatchIndex < rowMatches.count {
                        let match = rowMatches[currentMatchIndex]
                        if col >= match.start && col <= match.end {
                            searchMatchType = match.isCurrent ? 2 : 1
                        }
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
                if transientTextOverlayCoversCell {
                    // Keep the layout/background space, but defer visible glyphs to the transient overlay.
                } else if Self.couldBeRenderedAsBlockElement(cell.codepoint) && renderBlockElementIfNeeded(
                    codepoint: cell.codepoint,
                    x: x, y: y, w: w, h: h,
                    color: fgColor,
                    vertices: &vd.overlayVertices
                ) {
                    // no-op
                } else if cell.codepoint > 0x20 { // Skip spaces
                    let colorGlyph: GlyphAtlas.GlyphInfo?
                    if Self.shouldAttemptColorEmoji(for: cell) {
                        colorGlyph = cell.graphemeCacheKey().flatMap { glyphAtlas.colorGlyphInfo(for: $0) }
                    } else {
                        colorGlyph = nil
                    }
                    let glyph = colorGlyph ?? glyphInfoForCell(cell)
                    guard let glyph, glyph.pixelWidth > 0 else {
                        continue
                    }

                    let rawGlyphX: Float
                    if cell.width == 1 {
                        rawGlyphX = x + glyph.cellOffsetX
                    } else {
                        rawGlyphX = x + Self.wideGlyphOffsetX(
                            glyph,
                            spanWidth: w,
                            singleCellWidth: cellW
                        )
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

                    if colorGlyph != nil {
                        addQuad(to: &vd.colorGlyphVertices,
                               x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                               tx: glyph.textureX, ty: glyph.textureY,
                               tw: glyph.textureW, th: glyph.textureH,
                               fg: (1, 1, 1, 1),
                               bg: (0, 0, 0, 0))
                    } else {
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
                }

                if cell.attributes.underline {
                    addUnderlineDecoration(
                        to: &vd.overlayVertices,
                        cell: cell,
                        x: x,
                        y: y,
                        width: w,
                        height: h,
                        lineThickness: lineThickness,
                        color: effectiveUnderlineColor(for: cell, fallback: fgColor)
                    )
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
            let cursorOverlay = transientTextOverlays.last { $0.cursorRow != nil && $0.cursorCol != nil }
            let cursorCol = cursorOverlay?.cursorCol.map { min(max($0, 0), max(viewCols - 1, 0)) } ?? model.cursor.col
            let cursorRow = cursorOverlay?.cursorRow.map { min(max($0, 0), max(viewRows - 1, 0)) } ?? model.cursor.row
            let cx = padX + Float(cursorCol) * cellW
            let cy = padY + Float(cursorRow) * cellH
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

        for transientTextOverlay in transientTextOverlays {
            appendTransientTextOverlay(
                transientTextOverlay,
                scaleFactor: scaleFactor,
                cachedGlyphs: &cachedGlyphs,
                missingGlyphs: &missingGlyphs,
                to: &vd.glyphVertices
            )
        }

        // Scrollbar is handled by NSScroller overlay in TerminalView
        return vd
    }

    private func buildVertexData(snapshot: TerminalController.RenderSnapshot,
                                 selection: TerminalSelection?,
                                 searchHighlight: SearchHighlight? = nil,
                                 linkUnderline: LinkUnderline? = nil,
                                 transientTextOverlays: [TransientTextOverlay] = [],
                                 scaleFactor: Float,
                                 bufferSet: ViewBufferSet) -> VertexData {
        let vd = bufferSet.terminalVertexScratch
        vd.reset()
        var cachedGlyphs: [UInt32: GlyphAtlas.GlyphInfo] = [:]
        var missingGlyphs: Set<UInt32> = []

        let cellW = Float(glyphAtlas.cellWidth) * scaleFactor
        let cellH = Float(glyphAtlas.cellHeight) * scaleFactor
        let padX = Float(gridPadding) * scaleFactor
        let padY = Float(gridPadding) * scaleFactor
        let lineThickness = max(1.0, scaleFactor)
        let cursorThickness = max(1.0, scaleFactor * 2.0)

        let viewRows = snapshot.visibleRows.count
        let viewCols = snapshot.cols
        let approximateCellCount = max(1, viewRows * viewCols)
        vd.bgVertices.reserveCapacity(approximateCellCount * floatsPerQuad)
        vd.glyphVertices.reserveCapacity(approximateCellCount * floatsPerQuad * 2)
        vd.colorGlyphVertices.reserveCapacity(approximateCellCount * floatsPerQuad)
        vd.cursorVertices.reserveCapacity(floatsPerQuad)
        vd.overlayVertices.reserveCapacity(approximateCellCount * floatsPerQuad * 2)

        // Keep the per-view scratch arrays alive on the active render path so
        // idle/inactive cleanup can reclaim them deterministically. Tests also
        // assert that these reusable buffers exist after a rendered frame.
        prepareTerminalScrollbackRowsScratch(in: bufferSet, rowCount: viewRows)
        for row in 0..<viewRows {
            bufferSet.terminalScrollbackRowsScratch[row] = snapshot.visibleRows[row].cells
            bufferSet.terminalScrollbackRowHasData[row] = true
        }

        @inline(__always)
        func glyphInfo(for codepoint: UInt32) -> GlyphAtlas.GlyphInfo? {
            if let cached = cachedGlyphs[codepoint] {
                return cached
            }
            if missingGlyphs.contains(codepoint) {
                return nil
            }
            if let glyph = glyphAtlas.glyphInfo(for: codepoint) {
                cachedGlyphs[codepoint] = glyph
                return glyph
            }
            missingGlyphs.insert(codepoint)
            return nil
        }

        @inline(__always)
        func glyphInfoForCell(_ cell: Cell) -> GlyphAtlas.GlyphInfo? {
            if cell.hasGraphemeTail {
                guard let key = cell.graphemeCacheKey() else { return nil }
                return glyphAtlas.glyphInfo(for: key)
            }
            return glyphInfo(for: cell.codepoint)
        }

        prepareTerminalSearchMatchesScratch(in: bufferSet, rowCount: viewRows)
        if let sh = searchHighlight {
            for (i, match) in sh.matches.enumerated() {
                let visibleRow = match.absoluteRow - snapshot.firstVisibleAbsoluteRow
                guard visibleRow >= 0, visibleRow < viewRows else { continue }
                bufferSet.terminalSearchMatchesScratch[visibleRow].append(
                    SearchMatchSpan(start: match.startCol, end: match.endCol, isCurrent: sh.currentIndex == i)
                )
            }
        }
        let hasSelection = selection != nil
        let hasTransientTextOverlays = !transientTextOverlays.isEmpty
        let hasLinkUnderline = linkUnderline != nil
        let canUseCommonTextCellFastPath = !hasSelection && !hasTransientTextOverlays && !hasLinkUnderline && !snapshot.reverseVideo
        let defaultForeground = terminalAppearance.defaultForeground

        @inline(__always)
        func appendCommonDefaultRowGlyphs(
            rowSnapshot: TerminalController.RenderRowSnapshot,
            row: Int
        ) -> Bool {
            let cells = rowSnapshot.cells
            guard !cells.isEmpty else { return true }

            let lineAttribute = rowSnapshot.lineAttribute
            let lineColumnWidth = lineAttribute.isDoubleWidth ? cellW * 2.0 : cellW
            let lineHeightScale: Float = {
                switch lineAttribute {
                case .doubleHeightTop, .doubleHeightBottom:
                    return 2.0
                case .singleWidth, .doubleWidth:
                    return 1.0
                }
            }()
            let y = padY + Float(row) * cellH

            for (col, cell) in cells.enumerated() {
                if cell.hasInlineImage {
                    continue
                }
                if cell.isWideContinuation {
                    continue
                }
                if cell.attributes != .default {
                    return false
                }
                if cell.codepoint <= 0x20 {
                    continue
                }

                let x = padX + Float(col) * lineColumnWidth
                let w = lineColumnWidth * Float(max(1, cell.width))
                let h = cellH

                if Self.couldBeRenderedAsBlockElement(cell.codepoint) && renderBlockElementIfNeeded(
                    codepoint: cell.codepoint,
                    x: x, y: y, w: w, h: h,
                    color: defaultForeground,
                    vertices: &vd.overlayVertices
                ) {
                    continue
                }

                let colorGlyph: GlyphAtlas.GlyphInfo?
                if Self.shouldAttemptColorEmoji(for: cell) {
                    colorGlyph = cell.graphemeCacheKey().flatMap { glyphAtlas.colorGlyphInfo(for: $0) }
                } else {
                    colorGlyph = nil
                }
                guard let glyph = colorGlyph ?? glyphInfoForCell(cell), glyph.pixelWidth > 0 else {
                    continue
                }

                let rawGlyphX: Float
                if cell.width == 1 {
                    rawGlyphX = x + glyph.cellOffsetX
                } else {
                    rawGlyphX = x + Self.wideGlyphOffsetX(
                        glyph,
                        spanWidth: w,
                        singleCellWidth: cellW
                    )
                }
                let baselineScreenY = y + cellH - Float(glyphAtlas.baseline) * scaleFactor
                let rawGlyphY = baselineScreenY - glyph.baselineOffset
                let shouldSnapGlyphPosition = !glyphAtlas.usesOversampledRasterizationForCurrentDisplay
                let glyphX = shouldSnapGlyphPosition ? Self.snapToPixel(rawGlyphX) : rawGlyphX
                let glyphY = shouldSnapGlyphPosition ? Self.snapToPixel(rawGlyphY) : rawGlyphY
                let glyphW = Float(glyph.pixelWidth)
                let glyphH = Float(glyph.pixelHeight) * lineHeightScale
                let (textureY, textureH): (Float, Float) = {
                    switch lineAttribute {
                    case .doubleHeightTop:
                        return (glyph.textureY, glyph.textureH * 0.5)
                    case .doubleHeightBottom:
                        return (glyph.textureY + glyph.textureH * 0.5, glyph.textureH * 0.5)
                    case .singleWidth, .doubleWidth:
                        return (glyph.textureY, glyph.textureH)
                    }
                }()

                if colorGlyph != nil {
                    addQuad(to: &vd.colorGlyphVertices,
                            x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                            tx: glyph.textureX, ty: textureY,
                            tw: glyph.textureW, th: textureH,
                            fg: (1, 1, 1, 1),
                            bg: (0, 0, 0, 0))
                } else {
                    addQuad(to: &vd.glyphVertices,
                            x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                            tx: glyph.textureX, ty: textureY,
                            tw: glyph.textureW, th: textureH,
                            fg: (defaultForeground.r, defaultForeground.g, defaultForeground.b, 1),
                            bg: (0, 0, 0, 0))
                }
            }

            return true
        }

        if snapshot.hasInlineImages {
            let imagePlacements = snapshot.inlineImagePlacements
            vd.inlineImageDraws.reserveCapacity(imagePlacements.count)
            for placement in imagePlacements {
                let x = padX + Float(placement.startCol) * cellW
                let y = padY + Float(placement.row) * cellH
                let w = Float(placement.endCol - placement.startCol + 1) * cellW
                let h = Float(max(placement.rowSpan, 1)) * cellH
                var vertices: [Float] = []
                vertices.reserveCapacity(floatsPerQuad)
                addQuad(
                    to: &vertices,
                    x: x,
                    y: y,
                    w: w,
                    h: h,
                    tx: 0,
                    ty: 0,
                    tw: 1,
                    th: 1,
                    fg: (1, 1, 1, 1),
                    bg: (0, 0, 0, 0)
                )
                guard let ownerID = placement.ownerID else { continue }
                vd.inlineImageDraws.append(.init(ownerID: ownerID, index: placement.index, vertices: vertices))
            }
        }

        for row in 0..<viewRows {
            let rowSnapshot = snapshot.visibleRows[row]
            let lineAttribute = rowSnapshot.lineAttribute
            let lineColumnWidth = lineAttribute.isDoubleWidth ? cellW * 2.0 : cellW
            let lineHeightScale: Float = {
                switch lineAttribute {
                case .doubleHeightTop, .doubleHeightBottom:
                    return 2.0
                case .singleWidth, .doubleWidth:
                    return 1.0
                }
            }()
            let rowMatches = bufferSet.terminalSearchMatchesScratch[row]
            let rowHasMatches = !rowMatches.isEmpty
            var currentMatchIndex = 0
            let selectedColumnRange: ClosedRange<Int>? = {
                guard hasSelection, let selection else { return nil }
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

            if canUseCommonTextCellFastPath && !rowHasMatches &&
                appendCommonDefaultRowGlyphs(rowSnapshot: rowSnapshot, row: row) {
                continue
            }

            for col in 0..<viewCols {
                let transientTextOverlayCoversCell = hasTransientTextOverlays && transientTextOverlays.contains {
                    $0.masksGridGlyphs &&
                    row == $0.row &&
                    col >= $0.col &&
                    col < ($0.col + $0.columnWidth)
                }
                let cell = col < rowSnapshot.cells.count ? rowSnapshot.cells[col] : .empty

                if cell.hasInlineImage {
                    continue
                }
                if cell.isWideContinuation { continue }

                let x = padX + Float(col) * lineColumnWidth
                let y = padY + Float(row) * cellH
                let w = lineColumnWidth * Float(max(1, cell.width))
                let h = cellH

                if canUseCommonTextCellFastPath && !rowHasMatches && cell.attributes == .default {
                    if cell.codepoint <= 0x20 {
                        continue
                    }
                    if Self.couldBeRenderedAsBlockElement(cell.codepoint) && renderBlockElementIfNeeded(
                        codepoint: cell.codepoint,
                        x: x, y: y, w: w, h: h,
                        color: defaultForeground,
                        vertices: &vd.overlayVertices
                    ) {
                        continue
                    }

                    let colorGlyph: GlyphAtlas.GlyphInfo?
                    if Self.shouldAttemptColorEmoji(for: cell) {
                        colorGlyph = cell.graphemeCacheKey().flatMap { glyphAtlas.colorGlyphInfo(for: $0) }
                    } else {
                        colorGlyph = nil
                    }
                    let glyph = colorGlyph ?? glyphInfoForCell(cell)
                    guard let glyph, glyph.pixelWidth > 0 else {
                        continue
                    }

                    let rawGlyphX: Float
                    if cell.width == 1 {
                        rawGlyphX = x + glyph.cellOffsetX
                    } else {
                        rawGlyphX = x + Self.wideGlyphOffsetX(
                            glyph,
                            spanWidth: w,
                            singleCellWidth: cellW
                        )
                    }
                    let baselineScreenY = y + cellH - Float(glyphAtlas.baseline) * scaleFactor
                    let rawGlyphY = baselineScreenY - glyph.baselineOffset
                    let shouldSnapGlyphPosition = !glyphAtlas.usesOversampledRasterizationForCurrentDisplay
                    let glyphX = shouldSnapGlyphPosition ? Self.snapToPixel(rawGlyphX) : rawGlyphX
                    let glyphY = shouldSnapGlyphPosition ? Self.snapToPixel(rawGlyphY) : rawGlyphY
                    let glyphW = Float(glyph.pixelWidth)
                    let glyphH = Float(glyph.pixelHeight) * lineHeightScale
                    let (textureY, textureH): (Float, Float) = {
                        switch lineAttribute {
                        case .doubleHeightTop:
                            return (glyph.textureY, glyph.textureH * 0.5)
                        case .doubleHeightBottom:
                            return (glyph.textureY + glyph.textureH * 0.5, glyph.textureH * 0.5)
                        case .singleWidth, .doubleWidth:
                            return (glyph.textureY, glyph.textureH)
                        }
                    }()

                    if colorGlyph != nil {
                        addQuad(to: &vd.colorGlyphVertices,
                                x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                                tx: glyph.textureX, ty: textureY,
                                tw: glyph.textureW, th: textureH,
                                fg: (1, 1, 1, 1),
                                bg: (0, 0, 0, 0))
                    } else {
                        addQuad(to: &vd.glyphVertices,
                                x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                                tx: glyph.textureX, ty: textureY,
                                tw: glyph.textureW, th: textureH,
                                fg: (defaultForeground.r, defaultForeground.g, defaultForeground.b, 1),
                                bg: (0, 0, 0, 0))
                    }
                    continue
                }

                var fgColor: (r: Float, g: Float, b: Float)
                var bgColor: (r: Float, g: Float, b: Float, a: Float)

                let isSelected = hasSelection && (selectedColumnRange?.contains(col) ?? false)
                let usesDefaultBackground = cell.attributes.background.isDefaultColor

                var searchMatchType: Int = 0
                if rowHasMatches {
                    while currentMatchIndex < rowMatches.count && col > rowMatches[currentMatchIndex].end {
                        currentMatchIndex += 1
                    }
                    if currentMatchIndex < rowMatches.count {
                        let match = rowMatches[currentMatchIndex]
                        if col >= match.start && col <= match.end {
                            searchMatchType = match.isCurrent ? 2 : 1
                        }
                    }
                }

                let effectiveInverse = (cell.attributes.inverse != isSelected) != snapshot.reverseVideo
                if effectiveInverse {
                    fgColor = resolveBackgroundColorAsForeground(cell.attributes.background)
                    bgColor = resolveForegroundColorAsBackground(cell.attributes.foreground)
                } else {
                    fgColor = resolveForegroundColor(for: cell)
                    bgColor = resolveBackgroundColor(cell.attributes.background)
                }

                if searchMatchType == 2 {
                    bgColor = (0.90, 0.60, 0.10, 1.0)
                    fgColor = (0.0, 0.0, 0.0)
                } else if searchMatchType == 1 {
                    bgColor = (0.55, 0.45, 0.10, 1.0)
                    fgColor = (0.0, 0.0, 0.0)
                }

                if cell.attributes.hidden {
                    fgColor = (bgColor.r, bgColor.g, bgColor.b)
                } else if cell.attributes.dim && searchMatchType == 0 {
                    fgColor = (fgColor.r * 0.66, fgColor.g * 0.66, fgColor.b * 0.66)
                }

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

                if transientTextOverlayCoversCell {
                    // Keep the layout/background space, but defer visible glyphs to the transient overlay.
                } else if Self.couldBeRenderedAsBlockElement(cell.codepoint) && renderBlockElementIfNeeded(
                    codepoint: cell.codepoint,
                    x: x, y: y, w: w, h: h,
                    color: fgColor,
                    vertices: &vd.overlayVertices
                ) {
                    // no-op
                } else if cell.codepoint > 0x20 {
                    let colorGlyph: GlyphAtlas.GlyphInfo?
                    if Self.shouldAttemptColorEmoji(for: cell) {
                        colorGlyph = cell.graphemeCacheKey().flatMap { glyphAtlas.colorGlyphInfo(for: $0) }
                    } else {
                        colorGlyph = nil
                    }
                    let glyph = colorGlyph ?? glyphInfoForCell(cell)
                    guard let glyph, glyph.pixelWidth > 0 else {
                        continue
                    }

                    let rawGlyphX: Float
                    if cell.width == 1 {
                        rawGlyphX = x + glyph.cellOffsetX
                    } else {
                        rawGlyphX = x + Self.wideGlyphOffsetX(
                            glyph,
                            spanWidth: w,
                            singleCellWidth: cellW
                        )
                    }
                    let baselineScreenY = y + cellH - Float(glyphAtlas.baseline) * scaleFactor
                    let rawGlyphY = baselineScreenY - glyph.baselineOffset
                    let shouldSnapGlyphPosition = !glyphAtlas.usesOversampledRasterizationForCurrentDisplay
                    let glyphX = shouldSnapGlyphPosition ? Self.snapToPixel(rawGlyphX) : rawGlyphX
                    let glyphY = shouldSnapGlyphPosition ? Self.snapToPixel(rawGlyphY) : rawGlyphY
                    let glyphW = Float(glyph.pixelWidth)
                    let glyphH = Float(glyph.pixelHeight) * lineHeightScale
                    let (textureY, textureH): (Float, Float) = {
                        switch lineAttribute {
                        case .doubleHeightTop:
                            return (glyph.textureY, glyph.textureH * 0.5)
                        case .doubleHeightBottom:
                            return (glyph.textureY + glyph.textureH * 0.5, glyph.textureH * 0.5)
                        case .singleWidth, .doubleWidth:
                            return (glyph.textureY, glyph.textureH)
                        }
                    }()

                    if colorGlyph != nil {
                        addQuad(to: &vd.colorGlyphVertices,
                                x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                                tx: glyph.textureX, ty: textureY,
                                tw: glyph.textureW, th: textureH,
                                fg: (1, 1, 1, 1),
                                bg: (0, 0, 0, 0))
                    } else {
                        addQuad(to: &vd.glyphVertices,
                                x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                                tx: glyph.textureX, ty: textureY,
                                tw: glyph.textureW, th: textureH,
                                fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                                bg: (0, 0, 0, 0))

                        if cell.attributes.bold {
                            let boldOffset = max(1.0, ceil(scaleFactor * 0.5))
                            addQuad(to: &vd.glyphVertices,
                                    x: glyphX + boldOffset, y: glyphY, w: glyphW, h: glyphH,
                                    tx: glyph.textureX, ty: textureY,
                                    tw: glyph.textureW, th: textureH,
                                    fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                                    bg: (0, 0, 0, 0))
                        }
                    }
                }

                if cell.attributes.underline {
                    addUnderlineDecoration(
                        to: &vd.overlayVertices,
                        cell: cell,
                        x: x,
                        y: y,
                        width: w,
                        height: h,
                        lineThickness: lineThickness,
                        color: effectiveUnderlineColor(for: cell, fallback: fgColor)
                    )
                }

                if cell.attributes.strikethrough {
                    let strikeY = y + (h * 0.5) - (lineThickness * 0.5)
                    addQuad(to: &vd.overlayVertices, x: x, y: strikeY, w: w, h: lineThickness,
                            tx: 0, ty: 0, tw: 0, th: 0,
                            fg: (fgColor.r, fgColor.g, fgColor.b, 1),
                            bg: (fgColor.r, fgColor.g, fgColor.b, 1))
                }

                if let link = linkUnderline,
                   row == link.row && col >= link.startCol && col <= link.endCol {
                    let underlineY = y + h - lineThickness
                    addQuad(to: &vd.overlayVertices, x: x, y: underlineY, w: w, h: lineThickness,
                            tx: 0, ty: 0, tw: 0, th: 0,
                            fg: (0.4, 0.6, 1.0, 1.0),
                            bg: (0.4, 0.6, 1.0, 1.0))
                }
            }
        }

        if snapshot.scrollOffset == 0 && snapshot.cursor.visible && viewRows > 0 {
            let cursorOverlay = transientTextOverlays.last { $0.cursorRow != nil && $0.cursorCol != nil }
            let cursorCol = min(
                max(cursorOverlay?.cursorCol ?? snapshot.cursor.col, 0),
                max(viewCols - 1, 0)
            )
            let cursorRow = min(
                max(cursorOverlay?.cursorRow ?? snapshot.cursor.row, 0),
                max(viewRows - 1, 0)
            )
            let cursorLineAttribute = snapshot.visibleRows[cursorRow].lineAttribute
            let cursorColumnWidth = cursorLineAttribute.isDoubleWidth ? cellW * 2.0 : cellW
            let cx = padX + Float(cursorCol) * cursorColumnWidth
            let cy = padY + Float(cursorRow) * cellH
            let cursorColor: (Float, Float, Float, Float) = (0.8, 0.8, 0.8, 1)

            switch snapshot.cursor.shape {
            case .block:
                addQuad(to: &vd.cursorVertices, x: cx, y: cy, w: cursorColumnWidth, h: cellH,
                        tx: 0, ty: 0, tw: 0, th: 0,
                        fg: cursorColor, bg: cursorColor)
            case .underline:
                addQuad(to: &vd.cursorVertices, x: cx, y: cy + cellH - cursorThickness,
                        w: cursorColumnWidth, h: cursorThickness,
                        tx: 0, ty: 0, tw: 0, th: 0,
                        fg: cursorColor, bg: cursorColor)
            case .bar:
                addQuad(to: &vd.cursorVertices, x: cx, y: cy,
                        w: cursorThickness, h: cellH,
                        tx: 0, ty: 0, tw: 0, th: 0,
                        fg: cursorColor, bg: cursorColor)
            }
        }

        for transientTextOverlay in transientTextOverlays {
            appendTransientTextOverlay(
                transientTextOverlay,
                scaleFactor: scaleFactor,
                cachedGlyphs: &cachedGlyphs,
                missingGlyphs: &missingGlyphs,
                to: &vd.glyphVertices
            )
        }

        return vd
    }

    func debugBuildVertexDataForTesting(
        model: TerminalModel,
        scrollback: ScrollbackBuffer,
        scrollOffset: Int = 0,
        selection: TerminalSelection? = nil,
        transientTextOverlays: [TransientTextOverlay] = []
    ) -> VertexData {
        buildVertexData(
            model: model,
            scrollback: scrollback,
            scrollOffset: scrollOffset,
            selection: selection,
            searchHighlight: nil,
            linkUnderline: nil,
            transientTextOverlays: transientTextOverlays,
            scaleFactor: Float(glyphAtlas.scaleFactor),
            bufferSet: ViewBufferSet()
        )
    }

    func debugBuildVertexDataForTesting(
        snapshot: TerminalController.RenderSnapshot,
        selection: TerminalSelection? = nil,
        transientTextOverlays: [TransientTextOverlay] = []
    ) -> VertexData {
        buildVertexData(
            snapshot: snapshot,
            selection: selection,
            searchHighlight: nil,
            linkUnderline: nil,
            transientTextOverlays: transientTextOverlays,
            scaleFactor: Float(glyphAtlas.scaleFactor),
            bufferSet: ViewBufferSet()
        )
    }

    func debugRenderToTextureForTesting(
        model: TerminalModel,
        scrollback: ScrollbackBuffer,
        texture: MTLTexture,
        scrollOffset: Int = 0,
        selection: TerminalSelection? = nil,
        transientTextOverlays: [TransientTextOverlay] = [],
        suppressCursorBlink: Bool = true
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = terminalClearColor

        let viewportSize = SIMD2<Float>(Float(texture.width), Float(texture.height))
        var uniforms = MetalUniforms(
            viewportSize: viewportSize,
            positionOffset: .zero,
            cursorOpacity: (scrollOffset == 0 && model.cursor.visible) ? 1.0 : 0.0,
            cursorBlink: (model.cursor.blinking && !suppressCursorBlink) ? 1.0 : 0.0,
            time: Float(CACurrentMediaTime() - startTime)
        )
        let bufferSet = ViewBufferSet()
        let scaleFactor = Float(glyphAtlas.scaleFactor)
        let vertexData = buildVertexData(
            model: model,
            scrollback: scrollback,
            scrollOffset: scrollOffset,
            selection: selection,
            transientTextOverlays: transientTextOverlays,
            scaleFactor: scaleFactor,
            bufferSet: bufferSet
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        if !vertexData.bgVertices.isEmpty,
           let pipeline = bgPipeline,
           let buffer = makeTemporaryBuffer(vertices: vertexData.bgVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexData.bgVertices.count / floatsPerVertex)
        }

        drawMonochromeGlyphVertices(
            vertexData.glyphVertices,
            encoder: encoder,
            uniforms: &uniforms,
            buffer: makeTemporaryBuffer(vertices: vertexData.glyphVertices)
        )
        drawColorGlyphVertices(
            vertexData.colorGlyphVertices,
            encoder: encoder,
            uniforms: &uniforms,
            buffer: makeTemporaryBuffer(vertices: vertexData.colorGlyphVertices)
        )

        if !vertexData.cursorVertices.isEmpty,
           let pipeline = cursorPipeline,
           let buffer = makeTemporaryBuffer(vertices: vertexData.cursorVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexData.cursorVertices.count / floatsPerVertex)
        }

        if !vertexData.overlayVertices.isEmpty,
           let pipeline = overlayPipeline,
           let buffer = makeTemporaryBuffer(vertices: vertexData.overlayVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexData.overlayVertices.count / floatsPerVertex)
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func debugRenderToTextureForTesting(
        snapshot: TerminalController.RenderSnapshot,
        texture: MTLTexture,
        selection: TerminalSelection? = nil,
        transientTextOverlays: [TransientTextOverlay] = [],
        suppressCursorBlink: Bool = true
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = terminalClearColor

        let viewportSize = SIMD2<Float>(Float(texture.width), Float(texture.height))
        var uniforms = MetalUniforms(
            viewportSize: viewportSize,
            positionOffset: .zero,
            cursorOpacity: (snapshot.scrollOffset == 0 && snapshot.cursor.visible) ? 1.0 : 0.0,
            cursorBlink: (snapshot.cursor.blinking && !suppressCursorBlink) ? 1.0 : 0.0,
            time: Float(CACurrentMediaTime() - startTime)
        )
        let bufferSet = ViewBufferSet()
        let scaleFactor = Float(glyphAtlas.scaleFactor)
        let vertexData = buildVertexData(
            snapshot: snapshot,
            selection: selection,
            transientTextOverlays: transientTextOverlays,
            scaleFactor: scaleFactor,
            bufferSet: bufferSet
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        if !vertexData.bgVertices.isEmpty,
           let pipeline = bgPipeline,
           let buffer = makeTemporaryBuffer(vertices: vertexData.bgVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexData.bgVertices.count / floatsPerVertex)
        }

        drawMonochromeGlyphVertices(
            vertexData.glyphVertices,
            encoder: encoder,
            uniforms: &uniforms,
            buffer: makeTemporaryBuffer(vertices: vertexData.glyphVertices)
        )
        drawColorGlyphVertices(
            vertexData.colorGlyphVertices,
            encoder: encoder,
            uniforms: &uniforms,
            buffer: makeTemporaryBuffer(vertices: vertexData.colorGlyphVertices)
        )

        if !vertexData.cursorVertices.isEmpty,
           let pipeline = cursorPipeline,
           let buffer = makeTemporaryBuffer(vertices: vertexData.cursorVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexData.cursorVertices.count / floatsPerVertex)
        }

        if !vertexData.overlayVertices.isEmpty,
           let pipeline = overlayPipeline,
           let buffer = makeTemporaryBuffer(vertices: vertexData.overlayVertices) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexData.overlayVertices.count / floatsPerVertex)
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func debugRenderSplitCellToTextureForTesting(
        model: TerminalModel,
        scrollback: ScrollbackBuffer,
        texture: MTLTexture,
        scrollOffset: Int = 0,
        selection: TerminalSelection? = nil,
        borderConfig: BorderConfig? = nil,
        transientTextOverlays: [TransientTextOverlay] = [],
        suppressCursorBlink: Bool = true,
        cellRect: NSRect? = nil
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = terminalClearColor

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let debugView = MTKView(
            frame: NSRect(x: 0, y: 0, width: texture.width, height: texture.height),
            device: device
        )
        debugView.colorPixelFormat = Self.renderTargetPixelFormat
        let targetRect = cellRect ?? NSRect(x: 0, y: 0, width: texture.width, height: texture.height)
        renderSplitCell(
            model: model,
            scrollback: scrollback,
            scrollOffset: scrollOffset,
            selection: selection,
            borderConfig: borderConfig,
            transientTextOverlays: transientTextOverlays,
            suppressCursorBlink: suppressCursorBlink,
            encoder: encoder,
            viewportSize: SIMD2<Float>(Float(texture.width), Float(texture.height)),
            cellRect: targetRect,
            scaleFactor: Float(glyphAtlas.scaleFactor),
            in: debugView
        )

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func debugRenderSplitCellToTextureForTesting(
        snapshot: TerminalController.RenderSnapshot,
        texture: MTLTexture,
        selection: TerminalSelection? = nil,
        borderConfig: BorderConfig? = nil,
        transientTextOverlays: [TransientTextOverlay] = [],
        suppressCursorBlink: Bool = true,
        cellRect: NSRect? = nil,
        bufferOwner: MTKView? = nil
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = terminalClearColor

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let debugView = bufferOwner ?? {
            let view = MTKView(
                frame: NSRect(x: 0, y: 0, width: texture.width, height: texture.height),
                device: device
            )
            view.colorPixelFormat = Self.renderTargetPixelFormat
            return view
        }()
        let targetRect = cellRect ?? NSRect(x: 0, y: 0, width: texture.width, height: texture.height)
        renderSplitCell(
            snapshot: snapshot,
            selection: selection,
            borderConfig: borderConfig,
            transientTextOverlays: transientTextOverlays,
            suppressCursorBlink: suppressCursorBlink,
            encoder: encoder,
            viewportSize: SIMD2<Float>(Float(texture.width), Float(texture.height)),
            cellRect: targetRect,
            scaleFactor: Float(glyphAtlas.scaleFactor),
            in: debugView
        )

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func appendTransientTextOverlay(
        _ overlay: TransientTextOverlay,
        scaleFactor: Float,
        cachedGlyphs: inout [UInt32: GlyphAtlas.GlyphInfo],
        missingGlyphs: inout Set<UInt32>,
        to vertices: inout [Float]
    ) {
        guard overlay.alpha > 0.001 else { return }
        let cellW = Float(glyphAtlas.cellWidth) * scaleFactor
        let cellH = Float(glyphAtlas.cellHeight) * scaleFactor
        let padX = Float(gridPadding) * scaleFactor
        let padY = Float(gridPadding) * scaleFactor
        let baseX = padX + Float(overlay.col) * cellW
        let baseY = padY + Float(overlay.row) * cellH + overlay.verticalOffset * scaleFactor
        let shouldSnapGlyphPosition = !glyphAtlas.usesOversampledRasterizationForCurrentDisplay

        @inline(__always)
        func glyphInfo(for codepoint: UInt32) -> GlyphAtlas.GlyphInfo? {
            if let cached = cachedGlyphs[codepoint] {
                return cached
            }
            if missingGlyphs.contains(codepoint) {
                return nil
            }
            if let glyph = glyphAtlas.glyphInfo(for: codepoint) {
                cachedGlyphs[codepoint] = glyph
                return glyph
            }
            missingGlyphs.insert(codepoint)
            return nil
        }

        var columnOffset: Float = 0
        for scalar in overlay.text.unicodeScalars {
            guard scalar.value > 0x20,
                  let glyph = glyphInfo(for: scalar.value),
                  glyph.pixelWidth > 0 else {
                columnOffset += Float(max(CharacterWidth.width(of: scalar.value), 0)) * cellW
                continue
            }
            let characterWidth = max(CharacterWidth.width(of: scalar.value), 1)
            let x = baseX + columnOffset + (
                characterWidth == 1
                    ? glyph.cellOffsetX
                    : Self.wideGlyphOffsetX(
                        glyph,
                        spanWidth: Float(characterWidth) * cellW,
                        singleCellWidth: cellW
                    )
            )
            let baselineScreenY = baseY + cellH - Float(glyphAtlas.baseline) * scaleFactor
            let y = baselineScreenY - glyph.baselineOffset
            let glyphX = shouldSnapGlyphPosition ? Self.snapToPixel(x) : x
            let glyphY = shouldSnapGlyphPosition ? Self.snapToPixel(y) : y

            addQuad(to: &vertices,
                   x: glyphX, y: glyphY,
                   w: Float(glyph.pixelWidth), h: Float(glyph.pixelHeight),
                   tx: glyph.textureX, ty: glyph.textureY,
                   tw: glyph.textureW, th: glyph.textureH,
                   fg: (1.0, 1.0, 1.0, overlay.alpha),
                   bg: (0, 0, 0, 0))
            columnOffset += Float(characterWidth) * cellW
        }
    }

    private func resolveForegroundColor(for cell: Cell) -> (r: Float, g: Float, b: Float) {
        if cell.attributes.bold,
           case .indexed(let idx) = cell.attributes.foreground,
           idx < 8 {
            return TerminalColor.indexed(idx + 8).resolve(isForeground: true)
        }

        return resolveForegroundColor(cell.attributes.foreground)
    }

    private func effectiveUnderlineColor(
        for cell: Cell,
        fallback: (r: Float, g: Float, b: Float)
    ) -> (Float, Float, Float, Float) {
        if cell.attributes.underlineColor.isDefaultColor {
            return (fallback.r, fallback.g, fallback.b, 1.0)
        }
        let resolved = resolveForegroundColor(cell.attributes.underlineColor)
        return (resolved.r, resolved.g, resolved.b, 1.0)
    }

    private func addUnderlineDecoration(
        to vertices: inout [Float],
        cell: Cell,
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        lineThickness: Float,
        color: (Float, Float, Float, Float)
    ) {
        let underlineY = y + height - lineThickness
        switch cell.attributes.underlineStyle {
        case .single:
            addUnderlineQuad(to: &vertices, x: x, y: underlineY, width: width, thickness: lineThickness, color: color)
        case .double:
            addUnderlineQuad(to: &vertices, x: x, y: underlineY, width: width, thickness: lineThickness, color: color)
            let secondY = max(y, underlineY - lineThickness * 2.0)
            addUnderlineQuad(to: &vertices, x: x, y: secondY, width: width, thickness: lineThickness, color: color)
        case .curly:
            let segmentWidth = max(lineThickness * 2.0, width / 6.0)
            var offset: Float = 0
            var high = false
            while offset < width {
                let segment = min(segmentWidth, width - offset)
                let segmentY = underlineY - (high ? lineThickness : 0)
                addUnderlineQuad(to: &vertices, x: x + offset, y: segmentY, width: segment, thickness: lineThickness, color: color)
                high.toggle()
                offset += segmentWidth
            }
        case .dotted:
            let dotWidth = max(lineThickness, width / 10.0)
            let spacing = dotWidth
            var offset: Float = 0
            while offset < width {
                addUnderlineQuad(to: &vertices, x: x + offset, y: underlineY, width: min(dotWidth, width - offset), thickness: lineThickness, color: color)
                offset += dotWidth + spacing
            }
        case .dashed:
            let dashWidth = max(lineThickness * 3.0, width / 5.0)
            let gapWidth = max(lineThickness, dashWidth * 0.4)
            var offset: Float = 0
            while offset < width {
                addUnderlineQuad(to: &vertices, x: x + offset, y: underlineY, width: min(dashWidth, width - offset), thickness: lineThickness, color: color)
                offset += dashWidth + gapWidth
            }
        }
    }

    private func addUnderlineQuad(
        to vertices: inout [Float],
        x: Float,
        y: Float,
        width: Float,
        thickness: Float,
        color: (Float, Float, Float, Float)
    ) {
        addQuad(
            to: &vertices,
            x: x,
            y: y,
            w: width,
            h: thickness,
            tx: 0,
            ty: 0,
            tw: 0,
            th: 0,
            fg: color,
            bg: color
        )
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

    @inline(__always)
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
        let halfW = w * 0.5
        let halfH = h * 0.5
        let quarterH = max(1.0, h * 0.25)
        let eighthW = max(1.0, w * 0.125)

        @inline(__always)
        func addBlockQuad(_ dx: Float, _ dy: Float, _ dw: Float, _ dh: Float) {
            addQuad(to: &vertices,
                   x: x + dx, y: y + dy, w: dw, h: dh,
                   tx: 0, ty: 0, tw: 0, th: 0,
                   fg: (color.r, color.g, color.b, 1),
                   bg: (color.r, color.g, color.b, 1))
        }

        switch codepoint {
        case 0x2580:
            addBlockQuad(0, 0, w, halfH)
        case 0x2581:
            addBlockQuad(0, h - quarterH, w, quarterH)
        case 0x2584:
            addBlockQuad(0, halfH, w, halfH)
        case 0x2588:
            addBlockQuad(0, 0, w, h)
        case 0x258C:
            addBlockQuad(0, 0, halfW, h)
        case 0x258F:
            addBlockQuad(0, 0, eighthW, h)
        case 0x2590:
            addBlockQuad(halfW, 0, halfW, h)
        case 0x2595:
            addBlockQuad(w - eighthW, 0, eighthW, h)
        case 0x2596:
            addBlockQuad(0, halfH, halfW, halfH)
        case 0x2597:
            addBlockQuad(halfW, halfH, halfW, halfH)
        case 0x2598:
            addBlockQuad(0, 0, halfW, halfH)
        case 0x2599:
            addBlockQuad(0, 0, halfW, halfH)
            addBlockQuad(0, halfH, w, halfH)
        case 0x259A:
            addBlockQuad(0, 0, halfW, halfH)
            addBlockQuad(halfW, halfH, halfW, halfH)
        case 0x259B:
            addBlockQuad(0, 0, w, halfH)
            addBlockQuad(0, halfH, halfW, halfH)
        case 0x259C:
            addBlockQuad(0, 0, w, halfH)
            addBlockQuad(halfW, halfH, halfW, halfH)
        case 0x259D:
            addBlockQuad(halfW, 0, halfW, halfH)
        case 0x259E:
            addBlockQuad(halfW, 0, halfW, halfH)
            addBlockQuad(0, halfH, halfW, halfH)
        case 0x259F:
            addBlockQuad(halfW, 0, halfW, halfH)
            addBlockQuad(0, halfH, w, halfH)
        default:
            return false
        }
        return true
    }

    @inline(__always)
    private func appendVertexLinearized(to vertices: inout [Float],
                                        x: Float, y: Float,
                                        tx: Float, ty: Float,
                                        linearFG: (r: Float, g: Float, b: Float, a: Float),
                                        linearBG: (r: Float, g: Float, b: Float, a: Float)) {
        withUnsafeTemporaryAllocation(of: Float.self, capacity: floatsPerVertex) { buffer in
            buffer[0] = x
            buffer[1] = y
            buffer[2] = tx
            buffer[3] = ty
            buffer[4] = linearFG.r
            buffer[5] = linearFG.g
            buffer[6] = linearFG.b
            buffer[7] = linearFG.a
            buffer[8] = linearBG.r
            buffer[9] = linearBG.g
            buffer[10] = linearBG.b
            buffer[11] = linearBG.a
            vertices.append(contentsOf: buffer)
        }
    }

    /// Add a quad (2 triangles = 6 vertices) to the vertex array.
    @inline(__always)
    private func addQuad(to vertices: inout [Float],
                        x: Float, y: Float, w: Float, h: Float,
                        tx: Float, ty: Float, tw: Float, th: Float,
                        fg: (r: Float, g: Float, b: Float, a: Float),
                        bg: (r: Float, g: Float, b: Float, a: Float)) {
        let linearFG = Self.linearizeSRGBColor(r: fg.r, g: fg.g, b: fg.b, a: fg.a)
        let linearBG = Self.linearizeSRGBColor(r: bg.r, g: bg.g, b: bg.b, a: bg.a)
        withUnsafeTemporaryAllocation(of: Float.self, capacity: floatsPerQuad) { buffer in
            @inline(__always)
            func writeVertex(_ vertexIndex: Int, _ vx: Float, _ vy: Float, _ vtx: Float, _ vty: Float) {
                let base = vertexIndex * floatsPerVertex
                buffer[base] = vx
                buffer[base + 1] = vy
                buffer[base + 2] = vtx
                buffer[base + 3] = vty
                buffer[base + 4] = linearFG.r
                buffer[base + 5] = linearFG.g
                buffer[base + 6] = linearFG.b
                buffer[base + 7] = linearFG.a
                buffer[base + 8] = linearBG.r
                buffer[base + 9] = linearBG.g
                buffer[base + 10] = linearBG.b
                buffer[base + 11] = linearBG.a
            }

            writeVertex(0, x, y, tx, ty)
            writeVertex(1, x + w, y, tx + tw, ty)
            writeVertex(2, x, y + h, tx, ty + th)
            writeVertex(3, x + w, y, tx + tw, ty)
            writeVertex(4, x + w, y + h, tx + tw, ty + th)
            writeVertex(5, x, y + h, tx, ty + th)
            vertices.append(contentsOf: buffer)
        }
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
        case .overviewThumbnailSurface:
            return updateVertexBuffer(&bs.overviewThumbnailSurfaceBuffer, vertices: vertices)
        }
    }

    func makeOverviewThumbnailTexture(size: CGSize, scaleFactor: Float) -> MTLTexture? {
        let width = max(1, Int(ceil(size.width * CGFloat(scaleFactor))))
        let height = max(1, Int(ceil(size.height * CGFloat(scaleFactor))))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.renderTargetPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    func renderThumbnailToTexture(
        model: TerminalModel,
        scrollback: ScrollbackBuffer,
        scrollOffset: Int,
        texture: MTLTexture,
        thumbnailSize: NSSize,
        scaleFactor: Float,
        commandBuffer: MTLCommandBuffer,
        bgScratch: inout [Float],
        glyphScratch: inout [Float],
        colorGlyphScratch: inout [Float]
    ) {
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = terminalClearColor

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        renderThumbnail(
            model: model,
            scrollback: scrollback,
            scrollOffset: scrollOffset,
            encoder: encoder,
            viewportSize: SIMD2<Float>(Float(texture.width), Float(texture.height)),
            thumbnailRect: NSRect(origin: .zero, size: thumbnailSize),
            scaleFactor: scaleFactor,
            bgScratch: &bgScratch,
            glyphScratch: &glyphScratch,
            colorGlyphScratch: &colorGlyphScratch
        )

        encoder.endEncoding()
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
                         scaleFactor: Float,
                         bgScratch: inout [Float],
                         glyphScratch: inout [Float],
                         colorGlyphScratch: inout [Float]) {
        bgScratch.removeAll(keepingCapacity: true)
        glyphScratch.removeAll(keepingCapacity: true)
        colorGlyphScratch.removeAll(keepingCapacity: true)
        appendThumbnailVertexData(
            model: model,
            scrollback: scrollback,
            scrollOffset: scrollOffset,
            thumbnailRect: thumbnailRect,
            scaleFactor: scaleFactor,
            bgVertices: &bgScratch,
            glyphVertices: &glyphScratch,
            colorGlyphVertices: &colorGlyphScratch
        )

        // Draw thumbnail backgrounds
        var thumbUniforms = MetalUniforms(
            viewportSize: viewportSize,
            positionOffset: .zero,
            cursorOpacity: 0,
            time: 0
        )

        if !bgScratch.isEmpty, let pipeline = bgPipeline,
           let buf = makeTemporaryBuffer(vertices: bgScratch) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&thumbUniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: bgScratch.count / floatsPerVertex)
        }

        // Draw thumbnail glyphs (linear filtering for scaled-down text)
        drawMonochromeGlyphVertices(
            glyphScratch,
            encoder: encoder,
            uniforms: &thumbUniforms,
            buffer: makeTemporaryBuffer(vertices: glyphScratch)
        )
        drawColorGlyphVertices(
            colorGlyphScratch,
            encoder: encoder,
            uniforms: &thumbUniforms,
            buffer: makeTemporaryBuffer(vertices: colorGlyphScratch)
        )
    }

    func appendThumbnailVertexData(model: TerminalModel, scrollback: ScrollbackBuffer,
                                   scrollOffset: Int, thumbnailRect: NSRect,
                                   scaleFactor: Float,
                                   bgVertices: inout [Float],
                                   glyphVertices: inout [Float],
                                   colorGlyphVertices: inout [Float]) {
        var cachedGlyphs: [UInt32: GlyphAtlas.GlyphInfo] = [:]
        var missingGlyphs: Set<UInt32> = []
        let cellW = Float(glyphAtlas.cellWidth) * scaleFactor
        let cellH = Float(glyphAtlas.cellHeight) * scaleFactor
        let padX = Float(gridPadding) * scaleFactor
        let padY = Float(gridPadding) * scaleFactor

        let viewRows = model.rows
        let viewCols = model.cols
        let approximateCellCount = max(1, viewRows * viewCols)
        // A thumbnail cell can contribute up to one background quad and one glyph quad.
        // Reserve against full quad payloads so dirty thumbnail rebuilds don't repeatedly
        // grow the backing arrays while streaming output.
        bgVertices.reserveCapacity(bgVertices.count + approximateCellCount * floatsPerQuad)
        glyphVertices.reserveCapacity(glyphVertices.count + approximateCellCount * floatsPerQuad)
        colorGlyphVertices.reserveCapacity(colorGlyphVertices.count + approximateCellCount * floatsPerQuad)

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

        @inline(__always)
        func glyphInfo(for codepoint: UInt32) -> GlyphAtlas.GlyphInfo? {
            if let cached = cachedGlyphs[codepoint] {
                return cached
            }
            if missingGlyphs.contains(codepoint) {
                return nil
            }
            if let glyph = glyphAtlas.glyphInfo(for: codepoint) {
                cachedGlyphs[codepoint] = glyph
                return glyph
            }
            missingGlyphs.insert(codepoint)
            return nil
        }

        @inline(__always)
        func glyphInfoForCell(_ cell: Cell) -> GlyphAtlas.GlyphInfo? {
            if cell.hasGraphemeTail {
                guard let key = cell.graphemeCacheKey() else { return nil }
                return glyphAtlas.glyphInfo(for: key)
            }
            return glyphInfo(for: cell.codepoint)
        }

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
                if cell.codepoint > 0x20 {
                    let colorGlyph: GlyphAtlas.GlyphInfo?
                    if Self.shouldAttemptColorEmoji(for: cell) {
                        colorGlyph = cell.graphemeCacheKey().flatMap { glyphAtlas.colorGlyphInfo(for: $0) }
                    } else {
                        colorGlyph = nil
                    }
                    let glyph = colorGlyph ?? glyphInfoForCell(cell)
                    guard let glyph, glyph.pixelWidth > 0 else {
                        continue
                    }
                    let glyphFullX = fullX + (
                        cell.width == 1
                            ? glyph.cellOffsetX
                            : Self.wideGlyphOffsetX(
                                glyph,
                                spanWidth: fullW,
                                singleCellWidth: cellW
                            )
                    )
                    let baselineScreenY = fullY + fullH - Float(glyphAtlas.baseline) * scaleFactor
                    let glyphFullY = baselineScreenY - glyph.baselineOffset
                    let glyphFullW = Float(glyph.pixelWidth)
                    let glyphFullH = Float(glyph.pixelHeight)

                    // Transform glyph to thumbnail space
                    let gx = offsetX + glyphFullX * thumbScale
                    let gy = offsetY + glyphFullY * thumbScale
                    let gw = glyphFullW * thumbScale
                    let gh = glyphFullH * thumbScale

                    if colorGlyph != nil {
                        addQuad(to: &colorGlyphVertices,
                               x: gx, y: gy, w: gw, h: gh,
                               tx: glyph.textureX, ty: glyph.textureY,
                               tw: glyph.textureW, th: glyph.textureH,
                               fg: (1, 1, 1, 1),
                               bg: (0, 0, 0, 0))
                    } else {
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
                         headerOverlayConfig: HeaderOverlayConfig? = nil,
                         transientTextOverlays: [TransientTextOverlay] = [],
                         suppressCursorBlink: Bool = false,
                         encoder: MTLRenderCommandEncoder,
                         viewportSize: SIMD2<Float>,
                         cellRect: NSRect,
                         scaleFactor: Float,
                         in view: MTKView) {
        // Build vertex data at full size (positions relative to (0,0))
        let vd = buildVertexData(model: model, scrollback: scrollback, scrollOffset: scrollOffset,
                                 selection: selection, searchHighlight: searchHighlight,
                                 linkUnderline: linkUnderline, transientTextOverlays: transientTextOverlays,
                                 scaleFactor: scaleFactor,
                                 bufferSet: bufferSet(for: view))
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
            positionOffset: SIMD2<Float>(offsetX, offsetY),
            cursorOpacity: (scrollOffset == 0 && model.cursor.visible) ? 1.0 : 0.0,
            cursorBlink: (model.cursor.blinking && !suppressCursorBlink) ? 1.0 : 0.0,
            time: Float(CACurrentMediaTime() - startTime)
        )

        // 1. Backgrounds
        if !vd.bgVertices.isEmpty, let pipeline = bgPipeline {
            if let buf = makeTemporaryBuffer(vertices: vd.bgVertices) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                      vertexCount: vd.bgVertices.count / floatsPerVertex)
            }
        }

        // 2. Glyphs
        drawMonochromeGlyphVertices(
            vd.glyphVertices,
            encoder: encoder,
            uniforms: &uniforms,
            buffer: makeTemporaryBuffer(vertices: vd.glyphVertices)
        )
        drawColorGlyphVertices(
            vd.colorGlyphVertices,
            encoder: encoder,
            uniforms: &uniforms,
            buffer: makeTemporaryBuffer(vertices: vd.colorGlyphVertices)
        )

        // 3. Cursor
        if !vd.cursorVertices.isEmpty, let pipeline = cursorPipeline {
            if let buf = makeTemporaryBuffer(vertices: vd.cursorVertices) {
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
            if let buf = makeTemporaryBuffer(vertices: vd.overlayVertices) {
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
            addQuad(to: &bv, x: 0, y: 0, w: cellPixelW, h: bw,
                   tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            // Bottom
            addQuad(to: &bv, x: 0, y: cellPixelH - bw, w: cellPixelW, h: bw,
                   tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            // Left
            addQuad(to: &bv, x: 0, y: bw, w: bw, h: cellPixelH - 2 * bw,
                   tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            // Right
            addQuad(to: &bv, x: cellPixelW - bw, y: bw, w: bw, h: cellPixelH - 2 * bw,
                   tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            if let buf = makeTemporaryBuffer(vertices: bv) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                      vertexCount: bv.count / floatsPerVertex)
            }
        }

        if let headerOverlayConfig, let overlayPipeline, let glyphPipeline = glyphPipelineForCurrentOutput(),
           let atlas = glyphAtlas.texture {
            let headerVertices = headerOverlayVertices(
                config: headerOverlayConfig,
                frame: CGRect(origin: .zero, size: cellRect.size),
                scaleFactor: scaleFactor
            )
            if !headerVertices.overlay.isEmpty,
               let buf = makeTemporaryBuffer(vertices: headerVertices.overlay) {
                encoder.setRenderPipelineState(overlayPipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                      vertexCount: headerVertices.overlay.count / floatsPerVertex)
            }
            if !headerVertices.glyphs.isEmpty,
               let buf = makeTemporaryBuffer(vertices: headerVertices.glyphs) {
                encoder.setRenderPipelineState(glyphPipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.setFragmentTexture(atlas, index: 0)
                encoder.setFragmentSamplerState(glyphSamplerForCurrentOutput(), index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                      vertexCount: headerVertices.glyphs.count / floatsPerVertex)
            }
        }
    }

    func renderSplitCell(snapshot: TerminalController.RenderSnapshot,
                         selection: TerminalSelection?,
                         searchHighlight: SearchHighlight? = nil,
                         linkUnderline: LinkUnderline? = nil,
                         borderConfig: BorderConfig? = nil,
                         headerOverlayConfig: HeaderOverlayConfig? = nil,
                         transientTextOverlays: [TransientTextOverlay] = [],
                         suppressCursorBlink: Bool = false,
                         encoder: MTLRenderCommandEncoder,
                         viewportSize: SIMD2<Float>,
                         cellRect: NSRect,
                         scaleFactor: Float,
                         in view: MTKView) {
        let vd = buildVertexData(
            snapshot: snapshot,
            selection: selection,
            searchHighlight: searchHighlight,
            linkUnderline: linkUnderline,
            transientTextOverlays: transientTextOverlays,
            scaleFactor: scaleFactor,
            bufferSet: bufferSet(for: view)
        )
        let offsetX = Float(cellRect.origin.x) * scaleFactor
        let offsetY = Float(cellRect.origin.y) * scaleFactor
        let cellPixelW = Float(cellRect.width) * scaleFactor
        let cellPixelH = Float(cellRect.height) * scaleFactor

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
            positionOffset: SIMD2<Float>(offsetX, offsetY),
            cursorOpacity: (snapshot.scrollOffset == 0 && snapshot.cursor.visible) ? 1.0 : 0.0,
            cursorBlink: (snapshot.cursor.blinking && !suppressCursorBlink) ? 1.0 : 0.0,
            time: Float(CACurrentMediaTime() - startTime)
        )

        if !vd.bgVertices.isEmpty, let pipeline = bgPipeline {
            if let buf = makeTemporaryBuffer(vertices: vd.bgVertices) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: vd.bgVertices.count / floatsPerVertex)
            }
        }

        drawMonochromeGlyphVertices(
            vd.glyphVertices,
            encoder: encoder,
            uniforms: &uniforms,
            buffer: makeTemporaryBuffer(vertices: vd.glyphVertices)
        )
        drawColorGlyphVertices(
            vd.colorGlyphVertices,
            encoder: encoder,
            uniforms: &uniforms,
            buffer: makeTemporaryBuffer(vertices: vd.colorGlyphVertices)
        )
        drawInlineImageDraws(
            vd.inlineImageDraws,
            encoder: encoder,
            uniforms: &uniforms
        )

        if !vd.cursorVertices.isEmpty, let pipeline = cursorPipeline {
            if let buf = makeTemporaryBuffer(vertices: vd.cursorVertices) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: vd.cursorVertices.count / floatsPerVertex)
            }
        }

        if !vd.overlayVertices.isEmpty, let pipeline = overlayPipeline {
            if let buf = makeTemporaryBuffer(vertices: vd.overlayVertices) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: vd.overlayVertices.count / floatsPerVertex)
            }
        }

        if let border = borderConfig, let pipeline = overlayPipeline {
            var bv: [Float] = []
            let bw = border.width * scaleFactor
            let c = border.color
            addQuad(to: &bv, x: 0, y: 0, w: cellPixelW, h: bw,
                    tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            addQuad(to: &bv, x: 0, y: cellPixelH - bw, w: cellPixelW, h: bw,
                    tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            addQuad(to: &bv, x: 0, y: bw, w: bw, h: cellPixelH - 2 * bw,
                    tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            addQuad(to: &bv, x: cellPixelW - bw, y: bw, w: bw, h: cellPixelH - 2 * bw,
                    tx: 0, ty: 0, tw: 0, th: 0, fg: c, bg: (0, 0, 0, 0))
            if let buf = makeTemporaryBuffer(vertices: bv) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: bv.count / floatsPerVertex)
            }
        }

        if let headerOverlayConfig, let overlayPipeline, let glyphPipeline = glyphPipelineForCurrentOutput(),
           let atlas = glyphAtlas.texture {
            let headerVertices = headerOverlayVertices(
                config: headerOverlayConfig,
                frame: CGRect(origin: .zero, size: cellRect.size),
                scaleFactor: scaleFactor
            )
            if !headerVertices.overlay.isEmpty,
               let buf = makeTemporaryBuffer(vertices: headerVertices.overlay) {
                encoder.setRenderPipelineState(overlayPipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: headerVertices.overlay.count / floatsPerVertex)
            }
            if !headerVertices.glyphs.isEmpty,
               let buf = makeTemporaryBuffer(vertices: headerVertices.glyphs) {
                encoder.setRenderPipelineState(glyphPipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalUniforms>.size, index: 1)
                encoder.setFragmentTexture(atlas, index: 0)
                encoder.setFragmentSamplerState(glyphSamplerForCurrentOutput(), index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: headerVertices.glyphs.count / floatsPerVertex)
            }
        }
    }

    private func headerOverlayVertices(
        config: HeaderOverlayConfig,
        frame: CGRect,
        scaleFactor: Float
    ) -> (overlay: [Float], glyphs: [Float]) {
        guard !config.text.isEmpty else { return ([], []) }

        var overlayVertices: [Float] = []
        var glyphVertices: [Float] = []
        overlayVertices.reserveCapacity(floatsPerQuad * 2)

        let x = Float(frame.origin.x) * scaleFactor
        let y = Float(frame.origin.y) * scaleFactor
        let w = Float(frame.width) * scaleFactor
        let headerHeight = headerOverlayHeight(scaleFactor: scaleFactor)
        addQuad(
            to: &overlayVertices,
            x: x,
            y: y,
            w: w,
            h: headerHeight,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: config.backgroundColor,
            bg: (0, 0, 0, 0)
        )

        appendHeaderTextVertices(
            text: config.text,
            x: x + headerHorizontalPadding(scaleFactor: scaleFactor),
            y: y,
            availableWidth: max(0, w - headerHorizontalPadding(scaleFactor: scaleFactor) * 2),
            headerHeight: headerHeight,
            scaleFactor: scaleFactor,
            glyphScale: 0.82,
            color: config.textColor,
            usesBoldText: config.usesBoldText,
            to: &glyphVertices
        )

        return (overlayVertices, glyphVertices)
    }

    private func appendHeaderTextVertices(
        text: String,
        x: Float,
        y: Float,
        availableWidth: Float,
        headerHeight: Float,
        scaleFactor: Float,
        glyphScale: Float,
        color: (Float, Float, Float, Float),
        usesBoldText: Bool,
        to target: inout [Float]
    ) {
        guard availableWidth > 0 else { return }
        let fullText = truncatedHeaderText(text, availableWidth: availableWidth, scaleFactor: scaleFactor, glyphScale: glyphScale)
        guard !fullText.isEmpty else { return }

        let glyphCellHeight = Float(glyphAtlas.cellHeight) * scaleFactor * glyphScale
        let originY = y + max(0, floor((headerHeight - glyphCellHeight) * 0.5))
        var cursorX = x
        let singleCellAdvance = Float(glyphAtlas.cellWidth) * scaleFactor * glyphScale

        for scalar in fullText.unicodeScalars {
            let characterWidth = max(CharacterWidth.width(of: scalar.value), 1)
            let cellAdvance = Float(characterWidth) * singleCellAdvance

            guard let glyph = glyphAtlas.glyphInfo(for: scalar.value), glyph.pixelWidth > 0 else {
                cursorX += cellAdvance
                continue
            }

            let glyphX = cursorX + (
                characterWidth == 1
                    ? glyph.cellOffsetX * glyphScale
                    : Self.wideGlyphOffsetX(
                        glyph,
                        spanWidth: cellAdvance,
                        singleCellWidth: singleCellAdvance
                    )
            )
            let baselineY = originY + glyphCellHeight - Float(glyphAtlas.baseline) * scaleFactor * glyphScale
            let glyphY = baselineY - glyph.baselineOffset * glyphScale
            addQuad(
                to: &target,
                x: glyphX,
                y: glyphY,
                w: Float(glyph.pixelWidth) * glyphScale,
                h: Float(glyph.pixelHeight) * glyphScale,
                tx: glyph.textureX,
                ty: glyph.textureY,
                tw: glyph.textureW,
                th: glyph.textureH,
                fg: color,
                bg: (0, 0, 0, 0)
            )
            if usesBoldText {
                let boldOffset = max(1.0, ceil(scaleFactor * 0.4))
                addQuad(
                    to: &target,
                    x: glyphX + boldOffset,
                    y: glyphY,
                    w: Float(glyph.pixelWidth) * glyphScale,
                    h: Float(glyph.pixelHeight) * glyphScale,
                    tx: glyph.textureX,
                    ty: glyph.textureY,
                    tw: glyph.textureW,
                    th: glyph.textureH,
                    fg: color,
                    bg: (0, 0, 0, 0)
                )
            }
            cursorX += cellAdvance
        }
    }

    private func truncatedHeaderText(
        _ text: String,
        availableWidth: Float,
        scaleFactor: Float,
        glyphScale: Float
    ) -> String {
        let singleCellAdvance = Float(glyphAtlas.cellWidth) * scaleFactor * glyphScale
        guard singleCellAdvance > 0 else { return text }

        let ellipsis = "…"
        let ellipsisWidth = Float(max(CharacterWidth.width(of: 0x2026), 1)) * singleCellAdvance
        var consumedWidth: Float = 0
        var scalars: [Unicode.Scalar] = []
        let allScalars = Array(text.unicodeScalars)

        for (index, scalar) in allScalars.enumerated() {
            let scalarWidth = Float(max(CharacterWidth.width(of: scalar.value), 1)) * singleCellAdvance
            let remainingCount = allScalars.count - index - 1
            let reservedWidth = remainingCount > 0 ? ellipsisWidth : 0
            guard consumedWidth + scalarWidth + reservedWidth <= availableWidth else { break }
            scalars.append(scalar)
            consumedWidth += scalarWidth
        }

        guard scalars.count < allScalars.count else { return text }
        guard !scalars.isEmpty else { return availableWidth >= ellipsisWidth ? ellipsis : "" }
        return String(String.UnicodeScalarView(scalars)) + ellipsis
    }

    private func headerOverlayHeight(scaleFactor: Float) -> Float {
        ceil((Float(glyphAtlas.cellHeight) + 6.0) * scaleFactor)
    }

    private func headerHorizontalPadding(scaleFactor: Float) -> Float {
        max(scaleFactor * 6.0, scaleFactor)
    }

    private func prepareTerminalScrollbackRowsScratch(in bufferSet: ViewBufferSet, rowCount: Int) {
        if bufferSet.terminalScrollbackRowsScratch.count != rowCount {
            bufferSet.terminalScrollbackRowsScratch = Array(repeating: [], count: rowCount)
            bufferSet.terminalScrollbackRowHasData = Array(repeating: false, count: rowCount)
            return
        }
        for index in 0..<rowCount {
            bufferSet.terminalScrollbackRowsScratch[index].removeAll(keepingCapacity: true)
            bufferSet.terminalScrollbackRowHasData[index] = false
        }
    }

    private func prepareTerminalSearchMatchesScratch(in bufferSet: ViewBufferSet, rowCount: Int) {
        if bufferSet.terminalSearchMatchesScratch.count != rowCount {
            bufferSet.terminalSearchMatchesScratch = Array(repeating: [], count: rowCount)
            return
        }
        for index in 0..<rowCount {
            bufferSet.terminalSearchMatchesScratch[index].removeAll(keepingCapacity: true)
        }
    }
}

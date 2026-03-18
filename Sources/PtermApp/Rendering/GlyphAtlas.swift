import AppKit
import CoreText
import CoreGraphics
import Metal

/// Manages a texture atlas of rasterized glyphs using Core Text.
///
/// Rasterizes individual glyphs from the terminal font and packs them into
/// a Metal texture atlas. Handles Retina (HiDPI) rendering and font fallback
/// for CJK characters (delegated to Core Text's font cascade).
final class GlyphAtlas {
    /// Metal texture containing rasterized glyphs
    private(set) var texture: MTLTexture?
    private(set) var colorTexture: MTLTexture?

    /// Atlas dimensions (terminal points, before Retina scaling).
    private let initialAtlasDimension: Int
    private let maxAtlasDimension: Int
    private(set) var atlasDimension: Int

    /// Current packing position
    private var packX: Int = 0
    private var packY: Int = 0
    private var rowHeight: Int = 0
    private var colorPackX: Int = 0
    private var colorPackY: Int = 0
    private var colorRowHeight: Int = 0

    /// Glyph metrics cache. Last-access tracking lives inside GlyphInfo so the
    /// atlas does not pay for a second dictionary keyed by the same codepoints.
    private(set) var glyphCache: [UInt32: GlyphInfo] = [:]
    private var asciiGlyphCache: ContiguousArray<GlyphInfo?> = ContiguousArray(repeating: nil, count: 128)
    private(set) var clusterGlyphCache: [Cell.GraphemeCacheKey: GlyphInfo] = [:]
    private(set) var colorClusterGlyphCache: [Cell.GraphemeCacheKey: GlyphInfo] = [:]
    private var resolvedBMPFontCache: ContiguousArray<CTFont?> = ContiguousArray(repeating: nil, count: 0x10000)
    private var resolvedBMPGlyphCache: ContiguousArray<CGGlyph> = ContiguousArray(repeating: 0, count: 0x10000)
    private var resolvedBMPFontKnown: ContiguousArray<Bool> = ContiguousArray(repeating: false, count: 0x10000)
    private var accessGeneration: UInt64 = 0
    private(set) var atlasRevision: UInt64 = 0

    /// Font reference
    private var ctFont: CTFont

    /// Current font size (points)
    private(set) var fontSize: CGFloat

    /// Current font name
    private(set) var fontName: String

    /// Whether the atlas should eagerly seed printable ASCII.
    private let prerasterizeASCII: Bool

    /// Cell dimensions derived from font metrics
    private(set) var cellWidth: CGFloat = 0
    private(set) var cellHeight: CGFloat = 0
    private(set) var baseline: CGFloat = 0

    /// Scale factor for Retina
    private(set) var scaleFactor: CGFloat
    private var rasterScale: CGFloat {
        max(scaleFactor, 2.0)
    }
    private var glyphPaddingPixels: Int {
        max(2, Int(ceil(rasterScale * 0.5)))
    }
    var usesOversampledRasterizationForCurrentDisplay: Bool {
        rasterScale > scaleFactor
    }

    /// Metal device
    private let device: MTLDevice
    private var commandQueue: MTLCommandQueue?

    var texturePixelSize: (width: Int, height: Int)? {
        guard let texture else { return nil }
        return (texture.width, texture.height)
    }

    var debugHasCommandQueue: Bool {
        commandQueue != nil
    }

    struct GlyphInfo {
        var textureX: Float     // Texture coordinate X (0..1)
        var textureY: Float     // Texture coordinate Y (0..1)
        var textureW: Float     // Texture width (0..1)
        var textureH: Float     // Texture height (0..1)
        var cellOffsetX: Float  // Distance from terminal cell origin to bitmap left in display pixels
        var bitmapPadding: Float // Transparent atlas padding around the rasterized glyph in display pixels
        var bearingX: Float     // Horizontal bearing (points)
        var baselineOffset: Float // Distance from bitmap top to baseline in display pixels
        var pixelWidth: Int     // Display pixel width of glyph image
        var pixelHeight: Int    // Display pixel height of glyph image
        var advance: Float      // Horizontal advance (points)
        var lastAccessGeneration: UInt64
    }

    init(
        device: MTLDevice,
        fontSize: CGFloat,
        scaleFactor: CGFloat,
        initialAtlasDimension: Int = 128,
        maxAtlasDimension: Int = 2048,
        prerasterizeASCII: Bool = false
    ) {
        self.device = device
        self.commandQueue = nil
        self.scaleFactor = scaleFactor
        self.fontSize = fontSize
        self.initialAtlasDimension = initialAtlasDimension
        self.maxAtlasDimension = maxAtlasDimension
        self.atlasDimension = initialAtlasDimension
        self.prerasterizeASCII = prerasterizeASCII

        let defaultFont = Self.makeTerminalFont(size: fontSize)
        self.ctFont = defaultFont
        self.fontName = CTFontCopyPostScriptName(self.ctFont) as String
        calculateCellMetrics()
        if prerasterizeASCII {
            rebuildAtlas()
        }
    }

    // MARK: - Font Metrics

    private func calculateCellMetrics() {
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)

        cellHeight = ceil(ascent + descent + leading)
        // Keep terminal rows aligned to shared font metrics, but don't push all
        // leading above the baseline. Distributing half of the font leading
        // below the baseline gives descenders a little more room and matches
        // terminal-style line boxes better on low-DPI displays.
        baseline = ceil(descent + (leading * 0.5))

        // Measure 'M' for cell width (monospace font)
        let mChar: [UniChar] = [0x4D] // 'M'
        var glyphs: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(ctFont, mChar, &glyphs, 1)

        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advance, 1)
        cellWidth = ceil(advance.width)
    }

    // MARK: - Atlas Texture

    private func createAtlasTexture() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasDimension * Int(rasterScale),
            height: atlasDimension * Int(rasterScale),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        // Use shared storage on unified memory (Apple Silicon) to avoid
        // explicit CPU→GPU synchronization. Fall back to managed for discrete GPUs.
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed

        texture = device.makeTexture(descriptor: descriptor)
    }

    private func createColorAtlasTexture() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: atlasDimension * Int(rasterScale),
            height: atlasDimension * Int(rasterScale),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        colorTexture = device.makeTexture(descriptor: descriptor)
    }

    private func ensureAtlasTexture() {
        guard texture == nil else { return }
        createAtlasTexture()
    }

    private func ensureColorAtlasTexture() {
        guard colorTexture == nil else { return }
        createColorAtlasTexture()
    }

    // MARK: - Rasterization

    /// Get glyph info for a codepoint, rasterizing if not cached.
    func glyphInfo(for codepoint: UInt32) -> GlyphInfo? {
        accessGeneration &+= 1
        if codepoint < 128, var cached = asciiGlyphCache[Int(codepoint)] {
            cached.lastAccessGeneration = accessGeneration
            asciiGlyphCache[Int(codepoint)] = cached
            glyphCache[codepoint] = cached
            return cached
        }
        if var cached = glyphCache[codepoint] {
            cached.lastAccessGeneration = accessGeneration
            glyphCache[codepoint] = cached
            return cached
        }
        return rasterizeGlyph(codepoint: codepoint, allowAtlasGrowth: true)
    }

    func glyphInfo(for key: Cell.GraphemeCacheKey) -> GlyphInfo? {
        accessGeneration &+= 1
        if key.count == 1 {
            return glyphInfo(for: key.scalar0)
        }
        if var cached = clusterGlyphCache[key] {
            cached.lastAccessGeneration = accessGeneration
            clusterGlyphCache[key] = cached
            return cached
        }
        let text = key.renderedString()
        guard !text.isEmpty else { return nil }
        return rasterizeGlyph(text: text, cacheKey: key, allowAtlasGrowth: true)
    }

    func colorGlyphInfo(for key: Cell.GraphemeCacheKey) -> GlyphInfo? {
        accessGeneration &+= 1
        if var cached = colorClusterGlyphCache[key] {
            cached.lastAccessGeneration = accessGeneration
            colorClusterGlyphCache[key] = cached
            return cached
        }
        let text = key.renderedString()
        guard !text.isEmpty else { return nil }
        return rasterizeColorGlyph(text: text, cacheKey: key, allowAtlasGrowth: true)
    }

    /// Rasterize a single glyph and add it to the atlas.
    @discardableResult
    private func rasterizeGlyph(codepoint: UInt32, allowAtlasGrowth: Bool) -> GlyphInfo? {
        guard let scalar = Unicode.Scalar(codepoint) else { return nil }

        let run: (font: CTFont, glyph: CGGlyph)?
        if codepoint <= 0xFFFF {
            run = resolvedBMPFontAndGlyph(for: codepoint)
        } else {
            run = resolvedRunFontAndGlyph(for: scalar)
        }
        guard let run else { return nil }
        let runFont = run.font
        var glyph = run.glyph

        // Get glyph bounding box
        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(runFont, .horizontal, &glyph, &boundingRect, 1)

        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(runFont, .horizontal, &glyph, &advance, 1)

        // Calculate pixel dimensions
        let scale = rasterScale
        let displayScale = scaleFactor
        let paddingPixels = glyphPaddingPixels
        let pixelW = Int(ceil(boundingRect.width * scale)) + (paddingPixels * 2)
        let pixelH = Int(ceil(cellHeight * scale)) + (paddingPixels * 2)

        guard pixelW > 0, pixelH > 0 else {
            // Space or zero-width glyph
            let info = GlyphInfo(
                textureX: 0, textureY: 0, textureW: 0, textureH: 0,
                cellOffsetX: 0, bitmapPadding: 0, bearingX: 0, baselineOffset: 0,
                pixelWidth: 0, pixelHeight: 0,
                advance: Float(advance.width),
                lastAccessGeneration: accessGeneration
            )
            glyphCache[codepoint] = info
            return info
        }

        // Check if we need to advance to next row in atlas
        let atlasPixelW = atlasDimension * Int(scale)
        let atlasPixelH = atlasDimension * Int(scale)

        if packX + pixelW > atlasPixelW {
            packX = 0
            packY += rowHeight + 1
            rowHeight = 0
        }

        if packY + pixelH > atlasPixelH {
            guard allowAtlasGrowth, growAtlasAndRepack(adding: codepoint) else {
                return nil
            }
            return glyphCache[codepoint]
        }

        // Rasterize glyph to bitmap
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var bitmap = ContiguousArray<UInt8>(repeating: 0, count: pixelW * pixelH)
        let metrics = bitmap.withUnsafeMutableBytes { rawBytes -> (renderPixelWidth: Int, renderPixelHeight: Int, displayPadding: Float, cellOffsetX: Float, baselineOffset: Float)? in
            guard let baseAddress = rawBytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: pixelW,
                    height: pixelH,
                    bitsPerComponent: 8,
                    bytesPerRow: pixelW,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return nil
            }

            // Terminal glyphs need stable grayscale coverage, especially when composited
            // over translucent backgrounds on lower-DPI displays. Disable font smoothing
            // and subpixel positioning so the atlas stores predictable monochrome coverage
            // rather than display-specific LCD assumptions.
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setAllowsFontSmoothing(false)
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(false)
            context.setShouldSubpixelPositionFonts(false)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
            context.scaleBy(x: scale, y: scale)

            // Draw glyph into a zeroed grayscale bitmap to avoid an extra CoreGraphics fill pass.
            context.setFillColor(gray: 1, alpha: 1)
            let padding = CGFloat(paddingPixels) / scale
            let drawX = -boundingRect.origin.x + padding
            let drawY = ceil((baseline * scale) + CGFloat(paddingPixels)) / scale

            var position = CGPoint(x: drawX, y: drawY)
            CTFontDrawGlyphs(runFont, &glyph, &position, 1, context)

            ensureAtlasTexture()
            let region = MTLRegionMake2D(packX, packY, pixelW, pixelH)
            texture?.replace(region: region, mipmapLevel: 0, withBytes: baseAddress, bytesPerRow: pixelW)

            let renderPixelWidth = max(1, Int(round(CGFloat(pixelW) * displayScale / scale)))
            let renderPixelHeight = max(1, Int(round(CGFloat(pixelH) * displayScale / scale)))
            let displayPadding = Float((CGFloat(paddingPixels) * displayScale) / scale)
            let cellOffsetX = Float(
                (((cellWidth - advance.width) * 0.5) + boundingRect.origin.x) * displayScale
            )
            let baselineOffset = min(
                Float(renderPixelHeight),
                max(0, ((Float(pixelH) / Float(scale)) - Float(drawY)) * Float(displayScale))
            )
            return (renderPixelWidth, renderPixelHeight, displayPadding, cellOffsetX, baselineOffset)
        }
        guard let metrics else { return nil }

        let info = GlyphInfo(
            textureX: Float(packX) / Float(atlasPixelW),
            textureY: Float(packY) / Float(atlasPixelH),
            textureW: Float(pixelW) / Float(atlasPixelW),
            textureH: Float(pixelH) / Float(atlasPixelH),
            cellOffsetX: metrics.cellOffsetX,
            bitmapPadding: metrics.displayPadding,
            bearingX: Float(boundingRect.origin.x),
            baselineOffset: metrics.baselineOffset,
            pixelWidth: metrics.renderPixelWidth,
            pixelHeight: metrics.renderPixelHeight,
            advance: Float(advance.width),
            lastAccessGeneration: accessGeneration
        )

        glyphCache[codepoint] = info
        if codepoint < 128 {
            asciiGlyphCache[Int(codepoint)] = info
        }

        // Advance pack position
        packX += pixelW + 1
        rowHeight = max(rowHeight, pixelH)

        return info
    }

    private func resolvedBMPFontAndGlyph(for codepoint: UInt32) -> (font: CTFont, glyph: CGGlyph)? {
        let index = Int(codepoint)

        if resolvedBMPFontKnown[index] {
            guard let font = resolvedBMPFontCache[index] else { return nil }
            let glyph = resolvedBMPGlyphCache[index]
            guard glyph != 0 else {
                return nil
            }
            return (font, glyph)
        }

        let character = UniChar(codepoint)
        var characters = [character]
        var glyph: CGGlyph = 0
        if CTFontGetGlyphsForCharacters(ctFont, &characters, &glyph, 1), glyph != 0 {
            resolvedBMPFontCache[index] = ctFont
            resolvedBMPGlyphCache[index] = glyph
            resolvedBMPFontKnown[index] = true
            return (ctFont, glyph)
        }

        guard let scalar = Unicode.Scalar(codepoint) else {
            resolvedBMPFontKnown[index] = true
            resolvedBMPFontCache[index] = nil
            return nil
        }
        let string = String(Character(scalar)) as CFString
        let fallbackFont = CTFontCreateForString(ctFont, string, CFRangeMake(0, 1))

        glyph = 0
        if CTFontGetGlyphsForCharacters(fallbackFont, &characters, &glyph, 1), glyph != 0 {
            resolvedBMPFontCache[index] = fallbackFont
            resolvedBMPGlyphCache[index] = glyph
            resolvedBMPFontKnown[index] = true
            return (fallbackFont, glyph)
        }

        resolvedBMPFontKnown[index] = true
        resolvedBMPFontCache[index] = nil
        resolvedBMPGlyphCache[index] = 0
        return nil
    }

    private func resolvedRunFontAndGlyph(for scalar: Unicode.Scalar) -> (font: CTFont, glyph: CGGlyph)? {
        let string = String(Character(scalar)) as CFString
        let attrString = CFAttributedStringCreate(
            nil,
            string,
            [kCTFontAttributeName: ctFont] as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attrString)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        guard let run = runs.first else { return nil }
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
        var glyph: CGGlyph = 0
        CTRunGetGlyphs(run, CFRangeMake(0, 1), &glyph)
        guard glyph != 0 else { return nil }
        return (runFont, glyph)
    }

    @discardableResult
    private func rasterizeGlyph(text: String, cacheKey: Cell.GraphemeCacheKey, allowAtlasGrowth: Bool) -> GlyphInfo? {
        let attrString = CFAttributedStringCreate(
            nil,
            text as CFString,
            [kCTFontAttributeName: ctFont] as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds, .excludeTypographicLeading])
        let imageBounds = CTLineGetImageBounds(line, nil)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let scale = rasterScale
        let displayScale = scaleFactor
        let paddingPixels = glyphPaddingPixels
        let drawingBounds = imageBounds.isNull ? bounds : imageBounds
        let pixelW = max(1, Int(ceil(max(drawingBounds.width, advance) * scale)) + (paddingPixels * 2))
        let pixelH = Int(ceil(cellHeight * scale)) + (paddingPixels * 2)

        let atlasPixelW = atlasDimension * Int(scale)
        let atlasPixelH = atlasDimension * Int(scale)

        if packX + pixelW > atlasPixelW {
            packX = 0
            packY += rowHeight + 1
            rowHeight = 0
        }

        if packY + pixelH > atlasPixelH {
            guard allowAtlasGrowth, growAtlasAndRepack() else {
                return nil
            }
            return clusterGlyphCache[cacheKey]
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var bitmap = ContiguousArray<UInt8>(repeating: 0, count: pixelW * pixelH)
        let metrics = bitmap.withUnsafeMutableBytes { rawBytes -> (renderPixelWidth: Int, renderPixelHeight: Int, displayPadding: Float, cellOffsetX: Float, baselineOffset: Float)? in
            guard let baseAddress = rawBytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: pixelW,
                    height: pixelH,
                    bitsPerComponent: 8,
                    bytesPerRow: pixelW,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return nil
            }

            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setAllowsFontSmoothing(false)
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(false)
            context.setShouldSubpixelPositionFonts(false)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(gray: 1, alpha: 1)

            let padding = CGFloat(paddingPixels) / scale
            let drawY = ceil((baseline * scale) + CGFloat(paddingPixels)) / scale
            context.textPosition = CGPoint(x: padding, y: drawY)
            CTLineDraw(line, context)

            ensureAtlasTexture()
            let region = MTLRegionMake2D(packX, packY, pixelW, pixelH)
            texture?.replace(region: region, mipmapLevel: 0, withBytes: baseAddress, bytesPerRow: pixelW)

            let renderPixelWidth = max(1, Int(round(CGFloat(pixelW) * displayScale / scale)))
            let renderPixelHeight = max(1, Int(round(CGFloat(pixelH) * displayScale / scale)))
            let displayPadding = Float((CGFloat(paddingPixels) * displayScale) / scale)
            let cellOffsetX = Float(
                (((cellWidth - advance) * 0.5) + drawingBounds.origin.x) * displayScale
            )
            let baselineOffset = min(
                Float(renderPixelHeight),
                max(0, ((Float(pixelH) / Float(scale)) - Float(drawY)) * Float(displayScale))
            )
            return (renderPixelWidth, renderPixelHeight, displayPadding, cellOffsetX, baselineOffset)
        }
        guard let metrics else { return nil }
        let info = GlyphInfo(
            textureX: Float(packX) / Float(atlasPixelW),
            textureY: Float(packY) / Float(atlasPixelH),
            textureW: Float(pixelW) / Float(atlasPixelW),
            textureH: Float(pixelH) / Float(atlasPixelH),
            cellOffsetX: metrics.cellOffsetX,
            bitmapPadding: metrics.displayPadding,
            bearingX: Float(drawingBounds.origin.x),
            baselineOffset: metrics.baselineOffset,
            pixelWidth: metrics.renderPixelWidth,
            pixelHeight: metrics.renderPixelHeight,
            advance: Float(advance),
            lastAccessGeneration: accessGeneration
        )
        clusterGlyphCache[cacheKey] = info
        packX += pixelW + 1
        rowHeight = max(rowHeight, pixelH)
        return info
    }

    @discardableResult
    private func rasterizeColorGlyph(text: String, cacheKey: Cell.GraphemeCacheKey, allowAtlasGrowth: Bool) -> GlyphInfo? {
        let attrString = CFAttributedStringCreate(
            nil,
            text as CFString,
            [kCTFontAttributeName: ctFont] as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds, .excludeTypographicLeading])
        let imageBounds = CTLineGetImageBounds(line, nil)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let scale = rasterScale
        let displayScale = scaleFactor
        let paddingPixels = glyphPaddingPixels
        let drawingBounds = imageBounds.isNull ? bounds : imageBounds
        let pixelW = max(1, Int(ceil(max(drawingBounds.width, advance) * scale)) + (paddingPixels * 2))
        let pixelH = Int(ceil(cellHeight * scale)) + (paddingPixels * 2)

        let atlasPixelW = atlasDimension * Int(scale)
        let atlasPixelH = atlasDimension * Int(scale)

        if colorPackX + pixelW > atlasPixelW {
            colorPackX = 0
            colorPackY += colorRowHeight + 1
            colorRowHeight = 0
        }

        if colorPackY + pixelH > atlasPixelH {
            guard allowAtlasGrowth, growAtlasAndRepack(addingColorCluster: cacheKey) else {
                return nil
            }
            return colorClusterGlyphCache[cacheKey]
        }

        guard let context = CGContext(
                data: nil,
                width: pixelW,
                height: pixelH,
                bitsPerComponent: 8,
                bytesPerRow: pixelW * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                    CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        context.scaleBy(x: scale, y: scale)
        let padding = CGFloat(paddingPixels) / scale
        let drawY = ceil((baseline * scale) + CGFloat(paddingPixels)) / scale
        context.textPosition = CGPoint(x: padding, y: drawY)
        CTLineDraw(line, context)

        guard let data = context.data else { return nil }
        ensureColorAtlasTexture()
        let region = MTLRegionMake2D(colorPackX, colorPackY, pixelW, pixelH)
        colorTexture?.replace(region: region, mipmapLevel: 0, withBytes: data, bytesPerRow: pixelW * 4)

        let renderPixelWidth = max(1, Int(round(CGFloat(pixelW) * displayScale / scale)))
        let renderPixelHeight = max(1, Int(round(CGFloat(pixelH) * displayScale / scale)))
        let displayPadding = Float((CGFloat(paddingPixels) * displayScale) / scale)
        let cellOffsetX = Float(
            (((cellWidth - advance) * 0.5) + drawingBounds.origin.x) * displayScale
        )
        let baselineOffset = min(
            Float(renderPixelHeight),
            max(0, ((Float(pixelH) / Float(scale)) - Float(drawY)) * Float(displayScale))
        )
        let info = GlyphInfo(
            textureX: Float(colorPackX) / Float(atlasPixelW),
            textureY: Float(colorPackY) / Float(atlasPixelH),
            textureW: Float(pixelW) / Float(atlasPixelW),
            textureH: Float(pixelH) / Float(atlasPixelH),
            cellOffsetX: cellOffsetX,
            bitmapPadding: displayPadding,
            bearingX: Float(drawingBounds.origin.x),
            baselineOffset: baselineOffset,
            pixelWidth: renderPixelWidth,
            pixelHeight: renderPixelHeight,
            advance: Float(advance),
            lastAccessGeneration: accessGeneration
        )
        colorClusterGlyphCache[cacheKey] = info
        colorPackX += pixelW + 1
        colorRowHeight = max(colorRowHeight, pixelH)
        return info
    }

    /// Synchronize managed texture from CPU to GPU.
    /// No-op for shared storage (Apple Silicon unified memory).
    private func syncTextureToGPU(_ texture: MTLTexture?) {
        guard let texture, texture.storageMode == .managed else { return }
        if commandQueue == nil {
            commandQueue = device.makeCommandQueue()
        }
        guard let cmdBuf = commandQueue?.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else { return }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
    }

    // MARK: - Font Change

    func updateFont(name: String, size: CGFloat) {
        let font = Self.makeTerminalFont(name: name, size: size)
        self.ctFont = font
        self.fontName = CTFontCopyPostScriptName(font) as String
        self.fontSize = size
        rebuildAtlas()
    }

    /// Update the scale factor (e.g. when moving between Retina and non-Retina displays).
    func updateScaleFactor(_ newScale: CGFloat) {
        guard newScale != scaleFactor else { return }
        // scaleFactor is let, so we need to recreate — use a mutable shadow
        // Actually, let's make it var
        self.scaleFactor = newScale
        rebuildAtlas()
    }

    func resetToMinimum() {
        glyphCache.removeAll()
        asciiGlyphCache = ContiguousArray(repeating: nil, count: 128)
        clusterGlyphCache.removeAll()
        colorClusterGlyphCache.removeAll()
        resolvedBMPFontCache = ContiguousArray(repeating: nil, count: 0x10000)
        resolvedBMPGlyphCache = ContiguousArray(repeating: 0, count: 0x10000)
        resolvedBMPFontKnown = ContiguousArray(repeating: false, count: 0x10000)
        packX = 0
        packY = 0
        rowHeight = 0
        colorPackX = 0
        colorPackY = 0
        colorRowHeight = 0
        atlasDimension = initialAtlasDimension
        calculateCellMetrics()
        texture = nil
        colorTexture = nil
        atlasRevision &+= 1
    }

    @discardableResult
    func compactRetainingRecentlyUsedGlyphs(maximumInactiveGenerations: UInt64 = 4096) -> Bool {
        guard !glyphCache.isEmpty else {
            if atlasDimension > initialAtlasDimension {
                resetToMinimum()
                return true
            }
            return false
        }

        let currentGeneration = accessGeneration
        let retained = glyphCache.compactMap { entry -> UInt32? in
            let (codepoint, info) = entry
            guard currentGeneration &- info.lastAccessGeneration <= maximumInactiveGenerations else {
                return nil
            }
            return codepoint
        }
        let retainedClusters = clusterGlyphCache.compactMap { entry -> Cell.GraphemeCacheKey? in
            let (text, info) = entry
            guard currentGeneration &- info.lastAccessGeneration <= maximumInactiveGenerations else {
                return nil
            }
            return text
        }
        let retainedColorClusters = colorClusterGlyphCache.compactMap { entry -> Cell.GraphemeCacheKey? in
            let (text, info) = entry
            guard currentGeneration &- info.lastAccessGeneration <= maximumInactiveGenerations else {
                return nil
            }
            return text
        }

        guard retained.count < glyphCache.count ||
                retainedClusters.count < clusterGlyphCache.count ||
                retainedColorClusters.count < colorClusterGlyphCache.count ||
                atlasDimension > initialAtlasDimension else {
            return false
        }

        rebuildAtlasRetaining(
            Set(retained),
            retainedClusters: Set(retainedClusters),
            retainedColorClusters: Set(retainedColorClusters),
            resetToInitialSize: true
        )
        return true
    }

    private func rebuildAtlas() {
        rebuildAtlasRetaining(currentGlyphSet().union(prerasterizedASCIISet()),
                              retainedClusters: currentClusterGlyphSet(),
                              retainedColorClusters: currentColorClusterGlyphSet(),
                              resetToInitialSize: true)
    }

    private func rebuildAtlas(preserving additionalCodepoints: [UInt32], resetToInitialSize: Bool = false) {
        rebuildAtlasRetaining(currentGlyphSet().union(additionalCodepoints).union(prerasterizedASCIISet()),
                              retainedClusters: currentClusterGlyphSet(),
                              retainedColorClusters: currentColorClusterGlyphSet(),
                              resetToInitialSize: resetToInitialSize)
    }

    private func rebuildAtlasRetaining(
        _ required: Set<UInt32>,
        retainedClusters: Set<Cell.GraphemeCacheKey>,
        retainedColorClusters: Set<Cell.GraphemeCacheKey>,
        resetToInitialSize: Bool
    ) {
        if resetToInitialSize {
            atlasDimension = initialAtlasDimension
        }
        glyphCache.removeAll()
        asciiGlyphCache = ContiguousArray(repeating: nil, count: 128)
        clusterGlyphCache.removeAll()
        colorClusterGlyphCache.removeAll()
        resolvedBMPFontCache = ContiguousArray(repeating: nil, count: 0x10000)
        resolvedBMPGlyphCache = ContiguousArray(repeating: 0, count: 0x10000)
        resolvedBMPFontKnown = ContiguousArray(repeating: false, count: 0x10000)
        packX = 0
        packY = 0
        rowHeight = 0
        colorPackX = 0
        colorPackY = 0
        colorRowHeight = 0
        calculateCellMetrics()
        texture = nil
        colorTexture = nil
        atlasRevision &+= 1
        guard !required.isEmpty || !retainedClusters.isEmpty || !retainedColorClusters.isEmpty else { return }
        for codepoint in required.sorted() {
            _ = rasterizeGlyph(codepoint: codepoint, allowAtlasGrowth: true)
        }
        for key in retainedClusters.sorted(by: Cell.GraphemeCacheKey.isOrdered) {
            let text = key.renderedString()
            _ = rasterizeGlyph(text: text, cacheKey: key, allowAtlasGrowth: true)
        }
        for key in retainedColorClusters.sorted(by: Cell.GraphemeCacheKey.isOrdered) {
            let text = key.renderedString()
            _ = rasterizeColorGlyph(text: text, cacheKey: key, allowAtlasGrowth: true)
        }
        syncTextureToGPU(texture)
        syncTextureToGPU(colorTexture)
    }

    private func currentGlyphSet() -> Set<UInt32> {
        Set(glyphCache.keys)
    }

    private func currentClusterGlyphSet() -> Set<Cell.GraphemeCacheKey> {
        Set(clusterGlyphCache.keys)
    }

    private func currentColorClusterGlyphSet() -> Set<Cell.GraphemeCacheKey> {
        Set(colorClusterGlyphCache.keys)
    }

    private func prerasterizedASCIISet() -> Set<UInt32> {
        guard prerasterizeASCII else { return [] }
        return Set(UInt32(32)...UInt32(126))
    }

    private func nextAtlasDimension(after current: Int) -> Int {
        guard current < maxAtlasDimension else { return maxAtlasDimension }
        let grown = Int(ceil(CGFloat(current) * 1.5))
        let minimumStep = max(current + 1, grown)
        return min(maxAtlasDimension, minimumStep)
    }

    private func growAtlasAndRepack(adding codepoint: UInt32) -> Bool {
        guard atlasDimension < maxAtlasDimension else { return false }
        atlasDimension = nextAtlasDimension(after: atlasDimension)
        rebuildAtlas(preserving: [codepoint], resetToInitialSize: false)
        return glyphCache[codepoint] != nil
    }

    private func growAtlasAndRepack() -> Bool {
        guard atlasDimension < maxAtlasDimension else { return false }
        atlasDimension = nextAtlasDimension(after: atlasDimension)
        rebuildAtlas()
        return true
    }

    private func growAtlasAndRepack(addingColorCluster key: Cell.GraphemeCacheKey) -> Bool {
        guard atlasDimension < maxAtlasDimension else { return false }
        atlasDimension = nextAtlasDimension(after: atlasDimension)
        rebuildAtlasRetaining(
            currentGlyphSet().union(prerasterizedASCIISet()),
            retainedClusters: currentClusterGlyphSet(),
            retainedColorClusters: currentColorClusterGlyphSet().union([key]),
            resetToInitialSize: false
        )
        return colorClusterGlyphCache[key] != nil
    }

    private static func makeTerminalFont(name: String? = nil, size: CGFloat) -> CTFont {
        if let name {
            guard let font = NSFont(name: name, size: size) else {
                fatalError("Configured font is not available: \(name)")
            }
            return font as CTFont
        }

        for candidate in ["SFMono-Regular", "Menlo-Regular"] {
            if let font = NSFont(name: candidate, size: size) {
                return font as CTFont
            }
        }

        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
    }
}

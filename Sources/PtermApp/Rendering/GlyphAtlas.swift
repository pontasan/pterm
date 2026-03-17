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
    private(set) var clusterGlyphCache: [String: GlyphInfo] = [:]
    private(set) var colorClusterGlyphCache: [String: GlyphInfo] = [:]
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
        if var cached = glyphCache[codepoint] {
            cached.lastAccessGeneration = accessGeneration
            glyphCache[codepoint] = cached
            return cached
        }
        return rasterizeGlyph(codepoint: codepoint, allowAtlasGrowth: true)
    }

    func glyphInfo(for text: String) -> GlyphInfo? {
        guard !text.isEmpty else { return nil }
        if text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first {
            return glyphInfo(for: scalar.value)
        }
        accessGeneration &+= 1
        if var cached = clusterGlyphCache[text] {
            cached.lastAccessGeneration = accessGeneration
            clusterGlyphCache[text] = cached
            return cached
        }
        return rasterizeGlyph(text: text, cacheKey: text, allowAtlasGrowth: true)
    }

    func colorGlyphInfo(for text: String) -> GlyphInfo? {
        guard !text.isEmpty else { return nil }
        accessGeneration &+= 1
        if var cached = colorClusterGlyphCache[text] {
            cached.lastAccessGeneration = accessGeneration
            colorClusterGlyphCache[text] = cached
            return cached
        }
        return rasterizeColorGlyph(text: text, cacheKey: text, allowAtlasGrowth: true)
    }

    /// Rasterize a single glyph and add it to the atlas.
    @discardableResult
    private func rasterizeGlyph(codepoint: UInt32, allowAtlasGrowth: Bool) -> GlyphInfo? {
        guard let scalar = Unicode.Scalar(codepoint) else { return nil }

        // Get glyph from Core Text (handles font fallback for CJK automatically)
        let string = String(Character(scalar)) as CFString
        let attrString = CFAttributedStringCreate(
            nil, string,
            [kCTFontAttributeName: ctFont] as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attrString)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]

        guard let run = runs.first else { return nil }
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont

        var glyph: CGGlyph = 0
        CTRunGetGlyphs(run, CFRangeMake(0, 1), &glyph)

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
        let colorSpace = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: pixelW,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

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
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelW) / scale,
                           height: CGFloat(pixelH) / scale))

        // Draw glyph
        context.setFillColor(gray: 1, alpha: 1)
        let padding = CGFloat(paddingPixels) / scale
        let drawX = -boundingRect.origin.x + padding
        // Snap the baseline to an integer pixel boundary within the bitmap.
        // Without this, different glyphs have non-integer baseline offsets in
        // the bitmap, causing ±1px visual misalignment with nearest-neighbor sampling.
        // Use the font's shared baseline within a fixed-height cell bitmap.
        // This avoids glyph-specific top/bottom boxes leaking into terminal row
        // placement, which is what causes letters like "m", "d", and "t" to
        // drift relative to each other on 1x displays.
        let drawY = ceil((baseline * scale) + CGFloat(paddingPixels)) / scale

        var position = CGPoint(x: drawX, y: drawY)
        CTFontDrawGlyphs(runFont, &glyph, &position, 1, context)

        // Upload to atlas texture
        guard let data = context.data else { return nil }
        ensureAtlasTexture()
        let region = MTLRegionMake2D(packX, packY, pixelW, pixelH)
        texture?.replace(region: region, mipmapLevel: 0,
                        withBytes: data, bytesPerRow: pixelW)

        // Keep display metrics derived from the actual oversampled bitmap so the
        // top/baseline relationship survives the downscale exactly.
        let renderPixelWidth = max(1, Int(round(CGFloat(pixelW) * displayScale / scale)))
        let renderPixelHeight = max(1, Int(round(CGFloat(pixelH) * displayScale / scale)))
        let displayPadding = Float((CGFloat(paddingPixels) * displayScale) / scale)
        let cellOffsetX = Float(
            (((cellWidth - advance.width) * 0.5) + boundingRect.origin.x) * displayScale
        )
        // The baseline offset now comes from the shared cell baseline, not a
        // glyph-specific bounding box. That keeps every ASCII glyph aligned to
        // the same terminal row baseline across displays.
        let baselineOffset = min(
            Float(renderPixelHeight),
            max(0, ((Float(pixelH) / Float(scale)) - Float(drawY)) * Float(displayScale))
        )

        let info = GlyphInfo(
            textureX: Float(packX) / Float(atlasPixelW),
            textureY: Float(packY) / Float(atlasPixelH),
            textureW: Float(pixelW) / Float(atlasPixelW),
            textureH: Float(pixelH) / Float(atlasPixelH),
            cellOffsetX: cellOffsetX,
            bitmapPadding: displayPadding,
            bearingX: Float(boundingRect.origin.x),
            baselineOffset: baselineOffset,
            pixelWidth: renderPixelWidth,
            pixelHeight: renderPixelHeight,
            advance: Float(advance.width),
            lastAccessGeneration: accessGeneration
        )

        glyphCache[codepoint] = info

        // Advance pack position
        packX += pixelW + 1
        rowHeight = max(rowHeight, pixelH)

        return info
    }

    @discardableResult
    private func rasterizeGlyph(text: String, cacheKey: String, allowAtlasGrowth: Bool) -> GlyphInfo? {
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

        let colorSpace = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: pixelW,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        context.setAllowsFontSubpixelPositioning(false)
        context.setShouldSubpixelPositionFonts(false)
        context.setAllowsFontSubpixelQuantization(false)
        context.setShouldSubpixelQuantizeFonts(false)
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelW) / scale, height: CGFloat(pixelH) / scale))
        context.setFillColor(gray: 1, alpha: 1)

        let padding = CGFloat(paddingPixels) / scale
        let drawY = ceil((baseline * scale) + CGFloat(paddingPixels)) / scale
        context.textPosition = CGPoint(x: padding, y: drawY)
        CTLineDraw(line, context)

        guard let data = context.data else { return nil }
        ensureAtlasTexture()
        let region = MTLRegionMake2D(packX, packY, pixelW, pixelH)
        texture?.replace(region: region, mipmapLevel: 0, withBytes: data, bytesPerRow: pixelW)

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
            textureX: Float(packX) / Float(atlasPixelW),
            textureY: Float(packY) / Float(atlasPixelH),
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
        clusterGlyphCache[cacheKey] = info
        packX += pixelW + 1
        rowHeight = max(rowHeight, pixelH)
        return info
    }

    @discardableResult
    private func rasterizeColorGlyph(text: String, cacheKey: String, allowAtlasGrowth: Bool) -> GlyphInfo? {
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
        clusterGlyphCache.removeAll()
        colorClusterGlyphCache.removeAll()
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
        let retainedClusters = clusterGlyphCache.compactMap { entry -> String? in
            let (text, info) = entry
            guard currentGeneration &- info.lastAccessGeneration <= maximumInactiveGenerations else {
                return nil
            }
            return text
        }
        let retainedColorClusters = colorClusterGlyphCache.compactMap { entry -> String? in
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
        retainedClusters: Set<String>,
        retainedColorClusters: Set<String>,
        resetToInitialSize: Bool
    ) {
        if resetToInitialSize {
            atlasDimension = initialAtlasDimension
        }
        glyphCache.removeAll()
        clusterGlyphCache.removeAll()
        colorClusterGlyphCache.removeAll()
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
        for text in retainedClusters.sorted() {
            _ = rasterizeGlyph(text: text, cacheKey: text, allowAtlasGrowth: true)
        }
        for text in retainedColorClusters.sorted() {
            _ = rasterizeColorGlyph(text: text, cacheKey: text, allowAtlasGrowth: true)
        }
        syncTextureToGPU(texture)
        syncTextureToGPU(colorTexture)
    }

    private func currentGlyphSet() -> Set<UInt32> {
        Set(glyphCache.keys)
    }

    private func currentClusterGlyphSet() -> Set<String> {
        Set(clusterGlyphCache.keys)
    }

    private func currentColorClusterGlyphSet() -> Set<String> {
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

    private func growAtlasAndRepack(addingColorCluster text: String) -> Bool {
        guard atlasDimension < maxAtlasDimension else { return false }
        atlasDimension = nextAtlasDimension(after: atlasDimension)
        rebuildAtlasRetaining(
            currentGlyphSet().union(prerasterizedASCIISet()),
            retainedClusters: currentClusterGlyphSet(),
            retainedColorClusters: currentColorClusterGlyphSet().union([text]),
            resetToInitialSize: false
        )
        return colorClusterGlyphCache[text] != nil
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

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

    /// Atlas dimensions
    private let atlasWidth: Int = 2048
    private let atlasHeight: Int = 2048

    /// Current packing position
    private var packX: Int = 0
    private var packY: Int = 0
    private var rowHeight: Int = 0

    /// Glyph metrics cache
    private(set) var glyphCache: [UInt32: GlyphInfo] = [:]

    /// Font reference
    private var ctFont: CTFont

    /// Current font size (points)
    private(set) var fontSize: CGFloat

    /// Current font name
    private(set) var fontName: String

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
    private let commandQueue: MTLCommandQueue?

    struct GlyphInfo {
        var textureX: Float     // Texture coordinate X (0..1)
        var textureY: Float     // Texture coordinate Y (0..1)
        var textureW: Float     // Texture width (0..1)
        var textureH: Float     // Texture height (0..1)
        var cellOffsetX: Float  // Distance from terminal cell origin to bitmap left in display pixels
        var bearingX: Float     // Horizontal bearing (points)
        var baselineOffset: Float // Distance from bitmap top to baseline in display pixels
        var pixelWidth: Int     // Display pixel width of glyph image
        var pixelHeight: Int    // Display pixel height of glyph image
        var advance: Float      // Horizontal advance (points)
    }

    init(device: MTLDevice, fontSize: CGFloat, scaleFactor: CGFloat) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        self.scaleFactor = scaleFactor
        self.fontSize = fontSize

        let defaultFont = Self.makeTerminalFont(size: fontSize)
        self.ctFont = defaultFont
        self.fontName = CTFontCopyPostScriptName(self.ctFont) as String

        calculateCellMetrics()
        createAtlasTexture()
        prerasterizeASCII()
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
            width: atlasWidth * Int(rasterScale),
            height: atlasHeight * Int(rasterScale),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        // Use shared storage on unified memory (Apple Silicon) to avoid
        // explicit CPU→GPU synchronization. Fall back to managed for discrete GPUs.
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed

        texture = device.makeTexture(descriptor: descriptor)
    }

    // MARK: - Rasterization

    private func prerasterizeASCII() {
        // Pre-rasterize printable ASCII (32-126) for fast startup
        for cp in UInt32(32)...UInt32(126) {
            _ = rasterizeGlyph(codepoint: cp)
        }

        // Sync texture to GPU (only needed for managed storage)
        syncTextureToGPU()
    }

    /// Get glyph info for a codepoint, rasterizing if not cached.
    func glyphInfo(for codepoint: UInt32) -> GlyphInfo? {
        if let cached = glyphCache[codepoint] {
            return cached
        }
        return rasterizeGlyph(codepoint: codepoint)
    }

    /// Rasterize a single glyph and add it to the atlas.
    @discardableResult
    private func rasterizeGlyph(codepoint: UInt32) -> GlyphInfo? {
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
                cellOffsetX: 0, bearingX: 0, baselineOffset: 0,
                pixelWidth: 0, pixelHeight: 0,
                advance: Float(advance.width)
            )
            glyphCache[codepoint] = info
            return info
        }

        // Check if we need to advance to next row in atlas
        let atlasPixelW = atlasWidth * Int(scale)
        let atlasPixelH = atlasHeight * Int(scale)

        if packX + pixelW > atlasPixelW {
            packX = 0
            packY += rowHeight + 1
            rowHeight = 0
        }

        if packY + pixelH > atlasPixelH {
            // Atlas is full - in production, would create a new atlas page
            return nil
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
        let region = MTLRegionMake2D(packX, packY, pixelW, pixelH)
        texture?.replace(region: region, mipmapLevel: 0,
                        withBytes: data, bytesPerRow: pixelW)

        // Keep display metrics derived from the actual oversampled bitmap so the
        // top/baseline relationship survives the downscale exactly.
        let renderPixelWidth = max(1, Int(round(CGFloat(pixelW) * displayScale / scale)))
        let renderPixelHeight = max(1, Int(round(CGFloat(pixelH) * displayScale / scale)))
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
            bearingX: Float(boundingRect.origin.x),
            baselineOffset: baselineOffset,
            pixelWidth: renderPixelWidth,
            pixelHeight: renderPixelHeight,
            advance: Float(advance.width)
        )

        glyphCache[codepoint] = info

        // Advance pack position
        packX += pixelW + 1
        rowHeight = max(rowHeight, pixelH)

        return info
    }

    /// Synchronize managed texture from CPU to GPU.
    /// No-op for shared storage (Apple Silicon unified memory).
    private func syncTextureToGPU() {
        guard let texture = texture, texture.storageMode == .managed else { return }
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

    private func rebuildAtlas() {
        glyphCache.removeAll()
        packX = 0
        packY = 0
        rowHeight = 0
        calculateCellMetrics()
        createAtlasTexture()
        prerasterizeASCII()
    }

    private static func makeTerminalFont(name: String? = nil, size: CGFloat) -> CTFont {
        if let name {
            guard let font = NSFont(name: name, size: size) else {
                fatalError("Configured font is not available: \(name)")
            }
            return font as CTFont
        }

        for candidate in ["SFMono-Regular", ".SFNSMono-Regular", "Menlo-Regular"] {
            if let font = NSFont(name: candidate, size: size) {
                return font as CTFont
            }
        }

        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
    }
}

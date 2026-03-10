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

    /// Metal device
    private let device: MTLDevice

    struct GlyphInfo {
        var textureX: Float     // Texture coordinate X (0..1)
        var textureY: Float     // Texture coordinate Y (0..1)
        var textureW: Float     // Texture width (0..1)
        var textureH: Float     // Texture height (0..1)
        var bearingX: Float     // Horizontal bearing (points)
        var baselineOffset: Float // Distance from bitmap top to baseline (pixels, integer-snapped)
        var pixelWidth: Int     // Pixel width of glyph image
        var pixelHeight: Int    // Pixel height of glyph image
        var advance: Float      // Horizontal advance (points)
    }

    init(device: MTLDevice, fontSize: CGFloat, scaleFactor: CGFloat) {
        self.device = device
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
        baseline = ceil(descent)

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
            width: atlasWidth * Int(scaleFactor),
            height: atlasHeight * Int(scaleFactor),
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
        let scale = scaleFactor
        let pixelW = Int(ceil(boundingRect.width * scale)) + 2
        let pixelH = Int(ceil(boundingRect.height * scale)) + 2

        guard pixelW > 0, pixelH > 0 else {
            // Space or zero-width glyph
            let info = GlyphInfo(
                textureX: 0, textureY: 0, textureW: 0, textureH: 0,
                bearingX: 0, baselineOffset: 0,
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
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: pixelW,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelW) / scale,
                           height: CGFloat(pixelH) / scale))

        // Draw glyph
        context.setFillColor(gray: 1, alpha: 1)
        let drawX = -boundingRect.origin.x + 1.0 / scale
        // Snap the baseline to an integer pixel boundary within the bitmap.
        // Without this, different glyphs have non-integer baseline offsets in
        // the bitmap, causing ±1px visual misalignment with nearest-neighbor sampling.
        let drawY = ceil((-boundingRect.origin.y) * scale + 1.0) / scale

        var position = CGPoint(x: drawX, y: drawY)
        CTFontDrawGlyphs(runFont, &glyph, &position, 1, context)

        // Upload to atlas texture
        guard let data = context.data else { return nil }
        let region = MTLRegionMake2D(packX, packY, pixelW, pixelH)
        texture?.replace(region: region, mipmapLevel: 0,
                        withBytes: data, bytesPerRow: pixelW)

        // Baseline offset: distance from the top of the bitmap to the baseline (in pixels).
        // drawY * scale is the baseline position from the bottom of the bitmap,
        // which was snapped to an integer pixel above.
        let baselineFromBottom = ceil((-boundingRect.origin.y) * scale + 1.0)
        let baselineOffset = Float(pixelH) - Float(baselineFromBottom)

        let info = GlyphInfo(
            textureX: Float(packX) / Float(atlasPixelW),
            textureY: Float(packY) / Float(atlasPixelH),
            textureW: Float(pixelW) / Float(atlasPixelW),
            textureH: Float(pixelH) / Float(atlasPixelH),
            bearingX: Float(boundingRect.origin.x),
            baselineOffset: baselineOffset,
            pixelWidth: pixelW,
            pixelHeight: pixelH,
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
        guard let queue = device.makeCommandQueue(),
              let cmdBuf = queue.makeCommandBuffer(),
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
        if let name,
           let font = NSFont(name: name, size: size) {
            return font as CTFont
        }

        if let menlo = NSFont(name: "Menlo-Regular", size: size) {
            return menlo as CTFont
        }

        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
    }
}

import Foundation
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
    private let scaleFactor: CGFloat

    /// Metal device
    private let device: MTLDevice

    struct GlyphInfo {
        var textureX: Float     // Texture coordinate X (0..1)
        var textureY: Float     // Texture coordinate Y (0..1)
        var textureW: Float     // Texture width (0..1)
        var textureH: Float     // Texture height (0..1)
        var bearingX: Float     // Horizontal bearing (pixels)
        var bearingY: Float     // Vertical bearing (pixels)
        var pixelWidth: Int     // Pixel width of glyph image
        var pixelHeight: Int    // Pixel height of glyph image
        var advance: Float      // Horizontal advance (pixels)
    }

    init(device: MTLDevice, fontSize: CGFloat, scaleFactor: CGFloat) {
        self.device = device
        self.scaleFactor = scaleFactor
        self.fontSize = fontSize

        // Create font - SF Mono is the default
        let preferredName = "SFMono-Regular"
        if let font = CTFontCreateWithName(preferredName as CFString, fontSize, nil) as CTFont? {
            self.ctFont = font
            self.fontName = preferredName
        } else {
            // Fallback to Menlo if SF Mono unavailable
            let fallbackName = "Menlo-Regular"
            self.ctFont = CTFontCreateWithName(fallbackName as CFString,
                                                fontSize, nil)
            self.fontName = fallbackName
        }

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
        descriptor.storageMode = .managed

        texture = device.makeTexture(descriptor: descriptor)
    }

    // MARK: - Rasterization

    private func prerasterizeASCII() {
        // Pre-rasterize printable ASCII (32-126) for fast startup
        for cp in UInt32(32)...UInt32(126) {
            _ = rasterizeGlyph(codepoint: cp)
        }

        // Sync texture to GPU
        if let texture = texture,
           let blitEncoder = device.makeCommandQueue()?.makeCommandBuffer()?.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: texture)
            blitEncoder.endEncoding()
        }
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
                bearingX: 0, bearingY: 0,
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
        let drawY = -boundingRect.origin.y + 1.0 / scale

        var position = CGPoint(x: drawX, y: drawY)
        CTFontDrawGlyphs(runFont, &glyph, &position, 1, context)

        // Upload to atlas texture
        guard let data = context.data else { return nil }
        let region = MTLRegionMake2D(packX, packY, pixelW, pixelH)
        texture?.replace(region: region, mipmapLevel: 0,
                        withBytes: data, bytesPerRow: pixelW)

        let info = GlyphInfo(
            textureX: Float(packX) / Float(atlasPixelW),
            textureY: Float(packY) / Float(atlasPixelH),
            textureW: Float(pixelW) / Float(atlasPixelW),
            textureH: Float(pixelH) / Float(atlasPixelH),
            bearingX: Float(boundingRect.origin.x),
            bearingY: Float(boundingRect.origin.y),
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

    // MARK: - Font Change

    func updateFont(name: String, size: CGFloat) {
        if let font = CTFontCreateWithName(name as CFString, size, nil) as CTFont? {
            self.ctFont = font
            self.fontName = name
            self.fontSize = size
        }
        glyphCache.removeAll()
        packX = 0
        packY = 0
        rowHeight = 0
        calculateCellMetrics()
        createAtlasTexture()
        prerasterizeASCII()
    }
}

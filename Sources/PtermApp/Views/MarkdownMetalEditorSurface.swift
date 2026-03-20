import AppKit
import CoreText
import MetalKit
import QuartzCore

enum MarkdownMetalRendererFactory {
    static func make(font: NSFont, scaleFactor: CGFloat) -> MetalRenderer {
        guard let renderer = MetalRenderer(scaleFactor: scaleFactor) else {
            fatalError("Failed to initialize Metal. GPU rendering is required.")
        }
        if let library = loadShaderLibrary(using: renderer) {
            renderer.setupPipelines(library: library)
        } else {
            fatalError("Missing shader library for markdown editor renderer")
        }
        renderer.updateFont(name: renderableMonospaceFontName(preferred: font), size: font.pointSize)
        return renderer
    }

    private static func loadShaderLibrary(using renderer: MetalRenderer) -> MTLLibrary? {
        if let libraryURL = Bundle.main.url(forResource: "default", withExtension: "metallib"),
           let library = try? renderer.device.makeLibrary(URL: libraryURL) {
            return library
        }
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Rendering/Shaders/terminal.metal")
        if let source = try? String(contentsOf: sourceURL, encoding: .utf8),
           let library = try? renderer.device.makeLibrary(source: source, options: nil) {
            return library
        }
        return nil
    }

    private static func renderableMonospaceFontName(preferred font: NSFont) -> String {
        if !font.fontName.hasPrefix("."),
           NSFont(name: font.fontName, size: font.pointSize) != nil {
            return font.fontName
        }
        for candidate in ["SFMono-Regular", "Menlo-Regular"] {
            if NSFont(name: candidate, size: font.pointSize) != nil {
                return candidate
            }
        }
        return "Menlo-Regular"
    }
}

final class MarkdownEditorLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

final class MarkdownInputTextView: NSTextView {
    var onCommittedTextInserted: ((String, Int) -> Void)?
    var onDeletionPreviewRequested: ((String, CGRect, NSColor) -> Void)?
    var onVisualStateChanged: (() -> Void)?
    var inputFeedbackPlayer: TypewriterKeyClicking = TypewriterKeyClickPlayerFactory.defaultPlayer
    var typewriterSoundEnabled: Bool = TextInteractionConfiguration.default.typewriterSoundEnabled
    private(set) var renderMarkedRange = NSRange(location: NSNotFound, length: 0)
    private(set) var renderMarkedText: NSAttributedString?

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = if let attributed = string as? NSAttributedString {
            attributed.string
        } else if let plain = string as? String {
            plain
        } else {
            String(describing: string)
        }
        let priorSelection = selectedRange()
        super.insertText(string, replacementRange: replacementRange)
        clearMarkedTextRenderingState()
        guard !text.isEmpty else {
            onVisualStateChanged?()
            return
        }
        playInputFeedbackIfEnabled()
        let insertionLocation: Int
        if replacementRange.location != NSNotFound {
            insertionLocation = replacementRange.location
        } else {
            insertionLocation = priorSelection.location
        }
        onCommittedTextInserted?(text, insertionLocation)
        onVisualStateChanged?()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let attributed = if let value = string as? NSAttributedString {
            value
        } else if let plain = string as? String {
            NSAttributedString(string: plain)
        } else {
            NSAttributedString(string: String(describing: string))
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        renderMarkedRange = super.markedRange()
        renderMarkedText = attributed
        let text = attributed.string
        if !text.isEmpty {
            playInputFeedbackIfEnabled()
        }
        onVisualStateChanged?()
    }

    override func unmarkText() {
        super.unmarkText()
        clearMarkedTextRenderingState()
        onVisualStateChanged?()
    }

    override func didChangeText() {
        super.didChangeText()
        if super.markedRange().location == NSNotFound {
            clearMarkedTextRenderingState()
        }
        onVisualStateChanged?()
    }

    override func doCommand(by selector: Selector) {
        let priorString = string
        let deletionPreview = deletionPreviewData(for: selector)
        super.doCommand(by: selector)
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)),
             #selector(NSResponder.deleteForward(_:)):
            if priorString != string {
                playInputFeedbackIfEnabled()
                if let deletionPreview {
                    onDeletionPreviewRequested?(deletionPreview.text, deletionPreview.rect, deletionPreview.color)
                }
            }
        default:
            break
        }
    }

    private func deletionPreviewData(for selector: Selector) -> (text: String, rect: CGRect, color: NSColor)? {
        guard let textStorage,
              let layoutManager,
              let textContainer else {
            return nil
        }
        let currentSelection = selectedRange()
        let range: NSRange
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)):
            if currentSelection.length > 0 {
                range = currentSelection
            } else if currentSelection.location > 0 {
                let nsString = string as NSString
                range = nsString.rangeOfComposedCharacterSequence(at: currentSelection.location - 1)
            } else {
                return nil
            }
        case #selector(NSResponder.deleteForward(_:)):
            let nsString = string as NSString
            if currentSelection.length > 0 {
                range = currentSelection
            } else if currentSelection.location < nsString.length {
                range = nsString.rangeOfComposedCharacterSequence(at: currentSelection.location)
            } else {
                return nil
            }
        default:
            return nil
        }
        guard range.length > 0 else { return nil }
        layoutManager.ensureLayout(forCharacterRange: range)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        guard !rect.isEmpty else { return nil }
        let color = (textStorage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor) ??
            MarkdownHighlighter.defaultColor
        return ((string as NSString).substring(with: range), rect, color)
    }

    private func playInputFeedbackIfEnabled() {
        guard typewriterSoundEnabled else { return }
        inputFeedbackPlayer.playKeystroke()
    }

    private func clearMarkedTextRenderingState() {
        renderMarkedRange = NSRange(location: NSNotFound, length: 0)
        renderMarkedText = nil
    }
}

final class MarkdownMetalSurfaceView: MTKView, MTKViewDelegate {
    private enum PerformancePolicy {
        static let lineOverscanCount: CGFloat = 2
        static let largePayloadThreshold = 256 * 1024
        static let boundedHeadroomMultiplier = 1.25
        static let boundedHeadroomFloor = 4096
    }

    private struct Preview {
        enum Kind {
            case fadeIn
            case fadeOut
        }

        let text: String
        let rect: CGRect
        let color: NSColor
        let startedAt: CFTimeInterval
        let duration: CFTimeInterval
        let kind: Kind
        let maskedCharacterRange: NSRange?
    }

    private let renderer: MetalRenderer
    private weak var textView: NSTextView?
    private weak var clipView: NSClipView?
    private var previewTimer: Timer?
    private var previews: [Preview] = []
    private var markedTextLayer: CATextLayer?
    private var markedTextGlyphLayers: [CATextLayer] = []
    private var glyphVertexScratch: [Float] = []
    private var glyphBuffer: MTLBuffer?
    private var lastRenderedCharacterRange = NSRange(location: 0, length: 0)
    private var lastRenderedDocumentLength = 0
    private var lastRenderedBounds: CGRect = .zero
    private var lastRenderedScaleFactor: CGFloat = 0
    private let floatsPerVertex = 12
    private let transparentClear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var debugLastRenderedCharacterRange: NSRange { lastRenderedCharacterRange }
    var debugGlyphVertexFloatCount: Int { glyphVertexScratch.count }
    var debugHasReusableGlyphBuffer: Bool { glyphBuffer != nil }
    var debugActivePreviewCount: Int { previews.count }
    var debugMarkedTextLayerForTesting: CATextLayer? { markedTextLayer }
    var debugMarkedTextOverlayOriginsForTesting: [CGFloat] { markedTextGlyphLayers.map(\.frame.minX).sorted() }
    var debugMarkedTextOverlayFramesForTesting: [CGRect] {
        markedTextGlyphLayers.map(\.frame).sorted { lhs, rhs in
            if lhs.minX == rhs.minX {
                return lhs.minY < rhs.minY
            }
            return lhs.minX < rhs.minX
        }
    }
    var debugGlyphVerticesForTesting: [Float] { glyphVertexScratch }
    var debugRendererScaleFactorForTesting: CGFloat { renderer.glyphAtlas.scaleFactor }
    func debugCommittedGlyphOriginsForTesting() -> [CGFloat] {
        debugCommittedGlyphFramesForTesting().map(\.minX)
    }

    func debugCommittedGlyphFramesForTesting() -> [CGRect] {
        guard let textView,
              let clipView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return []
        }
        let nsString = textView.string as NSString
        let characterRange = debugCurrentCulledCharacterRange()
        guard characterRange.length > 0 else { return [] }
        var frames: [CGRect] = []
        var location = characterRange.location
        let end = NSMaxRange(characterRange)
        while location < end {
            let substringRange = nsString.rangeOfComposedCharacterSequence(at: location)
            let substring = nsString.substring(with: substringRange)
            defer { location = NSMaxRange(substringRange) }

            if shouldMaskGlyph(in: substringRange, textView: textView) {
                continue
            }
            guard substring != "\n",
                  let glyph = renderer.glyphAtlas.glyphInfo(for: substring.unicodeScalars.first?.value ?? 0),
                  glyph.textureW > 0 else {
                continue
            }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: substringRange, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            guard !rect.isEmpty else { continue }
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
            rect.origin.x -= clipView.documentVisibleRect.origin.x
            rect.origin.y -= clipView.documentVisibleRect.origin.y
            let glyphWidth = CGFloat(glyph.pixelWidth) / renderer.glyphAtlas.scaleFactor
            let glyphHeight = CGFloat(glyph.pixelHeight) / renderer.glyphAtlas.scaleFactor
            frames.append(CGRect(
                x: rect.origin.x + (CGFloat(glyph.cellOffsetX) / renderer.glyphAtlas.scaleFactor),
                y: bounds.height - rect.maxY,
                width: glyphWidth,
                height: glyphHeight
            ))
        }
        return frames.sorted { lhs, rhs in
            if lhs.minX == rhs.minX {
                return lhs.minY < rhs.minY
            }
            return lhs.minX < rhs.minX
        }
    }

    func debugUpdateMarkedTextOverlayNow() {
        updateMarkedTextOverlay()
    }

    func debugCurrentCulledCharacterRange() -> NSRange {
        guard let textView,
              let clipView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return NSRange(location: 0, length: 0)
        }
        let visibleRect = clipView.documentVisibleRect
        let cullingRect = expandedVisibleRect(
            visibleRect: visibleRect,
            textView: textView,
            layoutManager: layoutManager
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: cullingRect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    @discardableResult
    func debugPrepareVisibleGlyphsForTesting() -> Int {
        guard let textView,
              let clipView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            glyphVertexScratch.removeAll(keepingCapacity: true)
            lastRenderedCharacterRange = NSRange(location: 0, length: 0)
            return 0
        }
        pruneExpiredPreviews(now: CACurrentMediaTime())
        let scaleFactor = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        return rebuildVisibleGlyphVerticesIfNeeded(
            textView: textView,
            clipView: clipView,
            textContainer: textContainer,
            layoutManager: layoutManager,
            scaleFactor: scaleFactor
        )
    }

    init(frame: NSRect, renderer: MetalRenderer, textView: NSTextView, clipView: NSClipView) {
        self.renderer = renderer
        self.textView = textView
        self.clipView = clipView
        super.init(frame: frame, device: renderer.device)
        delegate = self
        preferredFramesPerSecond = 30
        colorPixelFormat = MetalRenderer.renderTargetPixelFormat
        clearColor = transparentClear
        framebufferOnly = true
        autoResizeDrawable = false
        isPaused = true
        enableSetNeedsDisplay = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        applyRenderTargetColorSpace()
        syncScaleFactor()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func requestRender() {
        ensureDrawableStorageAllocatedIfNeeded()
        updateMarkedTextOverlay()
        setNeedsDisplay(bounds)
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        ensureDrawableStorageAllocatedIfNeeded()
        super.setNeedsDisplay(invalidRect)
    }

    func syncFrameToClipView() {
        guard let clipView else { return }
        frame = clipView.bounds
        _ = syncDrawableSizeToBoundsIfNeeded()
        requestRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncScaleFactor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncScaleFactor()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        _ = syncDrawableSizeToBoundsIfNeeded()
        requestRender()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        _ = syncDrawableSizeToBoundsIfNeeded()
        requestRender()
    }

    func enqueueCommittedTextPreview(text: String, insertionLocation: Int) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let utf16Length = (text as NSString).length
        guard utf16Length > 0 else { return }
        let clampedLocation = max(0, min(insertionLocation, (textView.string as NSString).length))
        let range = NSRange(location: clampedLocation, length: min(utf16Length, (textView.string as NSString).length - clampedLocation))
        guard range.length > 0 else { return }

        layoutManager.ensureLayout(forCharacterRange: range)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height

        guard let visible = clipView?.documentVisibleRect, rect.intersects(visible) else { return }
        rect.origin.x -= visible.origin.x
        rect.origin.y -= visible.origin.y

        let color = (textView.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor) ??
            MarkdownHighlighter.defaultColor
        previews.append(Preview(
            text: text,
            rect: rect,
            color: color,
            startedAt: CACurrentMediaTime(),
            duration: 0.18,
            kind: .fadeIn,
            maskedCharacterRange: range
        ))
        if previews.count > 24 {
            previews.removeFirst(previews.count - 24)
        }
        invalidateCachedGlyphs()
        ensurePreviewTimer()
        requestRender()
    }

    func enqueueDeletionPreview(text: String, rect: CGRect, color: NSColor) {
        guard let visible = clipView?.documentVisibleRect else { return }
        guard rect.intersects(visible) else { return }
        var localRect = rect
        localRect.origin.x -= visible.origin.x
        localRect.origin.y -= visible.origin.y
        previews.append(Preview(
            text: text,
            rect: localRect,
            color: color,
            startedAt: CACurrentMediaTime(),
            duration: 0.34,
            kind: .fadeOut,
            maskedCharacterRange: nil
        ))
        if previews.count > 24 {
            previews.removeFirst(previews.count - 24)
        }
        invalidateCachedGlyphs()
        ensurePreviewTimer()
        requestRender()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let textView,
              let clipView,
              drawableSize.width > 0,
              drawableSize.height > 0,
              let commandQueue = renderer.commandQueue.makeCommandBuffer(),
              let renderPassDescriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let glyphPipeline = renderer.glyphPipeline,
              let sampler = renderer.samplerState,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return
        }

        let scaleFactor = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if renderer.glyphAtlas.scaleFactor != scaleFactor {
            renderer.glyphAtlas.updateScaleFactor(scaleFactor)
        }
        let now = CACurrentMediaTime()
        updateMarkedTextOverlay()
        pruneExpiredPreviews(now: now)

        renderPassDescriptor.colorAttachments[0].clearColor = transparentClear
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        let visibleRect = clipView.documentVisibleRect
        _ = rebuildVisibleGlyphVerticesIfNeeded(
            textView: textView,
            clipView: clipView,
            textContainer: textContainer,
            layoutManager: layoutManager,
            scaleFactor: scaleFactor
        )

        let nsString = textView.string as NSString
        var glyphVertices = glyphVertexScratch
        appendGlyphVertices(
            from: nsString,
            characterRange: NSRange(location: 0, length: 0),
            textView: textView,
            layoutManager: layoutManager,
            textContainer: textContainer,
            visibleRect: visibleRect,
            scaleFactor: Float(scaleFactor),
            into: &glyphVertices
        )

        appendPreviewVertices(scaleFactor: Float(scaleFactor), now: now, into: &glyphVertices)
        guard let encoder = commandQueue.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        var uniforms = MetalRenderer.MetalUniforms(
            viewportSize: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            cursorOpacity: 0,
            cursorBlink: 0,
            time: 0
        )

        if !glyphVertices.isEmpty,
           let atlasTexture = renderer.glyphAtlas.texture,
           let glyphBuffer = updateVertexBuffer(glyphBuffer, floats: glyphVertices) {
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setVertexBuffer(glyphBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalRenderer.MetalUniforms>.size, index: 1)
            encoder.setFragmentTexture(atlasTexture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: glyphVertices.count / floatsPerVertex)
        }

        encoder.endEncoding()
        commandQueue.present(drawable)
        commandQueue.commit()
    }

    @discardableResult
    private func rebuildVisibleGlyphVerticesIfNeeded(
        textView: NSTextView,
        clipView: NSClipView,
        textContainer: NSTextContainer,
        layoutManager: NSLayoutManager,
        scaleFactor: CGFloat
    ) -> Int {
        let visibleRect = clipView.documentVisibleRect
        let cullingRect = expandedVisibleRect(
            visibleRect: visibleRect,
            textView: textView,
            layoutManager: layoutManager
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: cullingRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let nsString = textView.string as NSString
        let documentLength = nsString.length
        let shouldRebuildGlyphs =
            characterRange.location != lastRenderedCharacterRange.location ||
            characterRange.length != lastRenderedCharacterRange.length ||
            documentLength != lastRenderedDocumentLength ||
            visibleRect != lastRenderedBounds ||
            scaleFactor != lastRenderedScaleFactor

        if shouldRebuildGlyphs {
            glyphVertexScratch.removeAll(keepingCapacity: true)
            glyphVertexScratch.reserveCapacity(max(characterRange.length, 1) * floatsPerVertex * 6)
            appendGlyphVertices(
                from: nsString,
                characterRange: characterRange,
                textView: textView,
                layoutManager: layoutManager,
                textContainer: textContainer,
                visibleRect: visibleRect,
                scaleFactor: Float(scaleFactor),
                into: &glyphVertexScratch
            )
            lastRenderedCharacterRange = characterRange
            lastRenderedDocumentLength = documentLength
            lastRenderedBounds = visibleRect
            lastRenderedScaleFactor = scaleFactor
            glyphBuffer = updateVertexBuffer(glyphBuffer, floats: glyphVertexScratch)
        }

        return glyphVertexScratch.count
    }

    private func syncScaleFactor() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.contentsScale = scale
        if renderer.glyphAtlas.scaleFactor != scale {
            renderer.glyphAtlas.updateScaleFactor(scale)
        }
        applyRenderTargetColorSpace()
        _ = syncDrawableSizeToBoundsIfNeeded()
        requestRender()
    }

    @discardableResult
    private func syncDrawableSizeToBoundsIfNeeded() -> Bool {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let expected = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard expected.width > 0, expected.height > 0 else { return false }
        guard abs(drawableSize.width - expected.width) > 1 ||
                abs(drawableSize.height - expected.height) > 1 else {
            return false
        }
        drawableSize = expected
        return true
    }

    private func ensureDrawableStorageAllocatedIfNeeded() {
        _ = syncDrawableSizeToBoundsIfNeeded()
    }

    private func applyRenderTargetColorSpace() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        metalLayer.colorspace = MetalRenderer.renderTargetColorSpace
        metalLayer.pixelFormat = MetalRenderer.renderTargetPixelFormat
        metalLayer.isOpaque = false
        if #available(macOS 10.13.2, *) {
            metalLayer.maximumDrawableCount = 2
        }
    }

    private func ensurePreviewTimer() {
        guard previewTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.previews.isEmpty {
                self.previewTimer?.invalidate()
                self.previewTimer = nil
                return
            }
            self.requestRender()
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func pruneExpiredPreviews(now: CFTimeInterval) {
        let priorCount = previews.count
        guard priorCount > 0 else { return }
        previews = previews.filter { now - $0.startedAt < $0.duration }
        guard previews.count != priorCount else { return }
        invalidateCachedGlyphs()
        if previews.isEmpty {
            previewTimer?.invalidate()
            previewTimer = nil
        }
    }

    private func configureMarkedTextLayer() {
        guard markedTextLayer == nil else { return }
        let textLayer = CATextLayer()
        textLayer.isHidden = true
        textLayer.alignmentMode = .left
        textLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        textLayer.isWrapped = false
        layer?.addSublayer(textLayer)
        markedTextLayer = textLayer
    }

    private func destroyMarkedTextLayer() {
        markedTextGlyphLayers.forEach { $0.removeFromSuperlayer() }
        markedTextGlyphLayers.removeAll(keepingCapacity: false)
        markedTextLayer?.removeFromSuperlayer()
        markedTextLayer = nil
    }

    private func updateMarkedTextOverlay() {
        guard let textView,
              let textStorage = textView.textStorage,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let clipView else {
            destroyMarkedTextLayer()
            return
        }
        let markedRange = markedRange(for: textView)
        guard markedRange.location != NSNotFound, markedRange.length > 0 else {
            destroyMarkedTextLayer()
            invalidateCachedGlyphs()
            return
        }

        configureMarkedTextLayer()
        guard let markedTextLayer else { return }

        layoutManager.ensureLayout(forCharacterRange: markedRange)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: markedRange, actualCharacterRange: nil)
        var textRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard !textRect.isEmpty else {
            markedTextLayer.isHidden = true
            return
        }
        textRect.origin.x += textView.textContainerInset.width
        textRect.origin.y += textView.textContainerInset.height
        textRect.origin.x -= clipView.documentVisibleRect.origin.x
        textRect.origin.y -= clipView.documentVisibleRect.origin.y

        let font = NSFont(name: renderer.glyphAtlas.fontName, size: renderer.glyphAtlas.fontSize)
            ?? textView.font
            ?? NSFont.monospacedSystemFont(ofSize: renderer.glyphAtlas.fontSize, weight: .regular)
        let markedString = markedAttributedString(for: textView)?.string ?? textStorage.attributedSubstring(from: markedRange).string
        let attributed = NSMutableAttributedString(
            string: markedString,
            attributes: [
                .font: font as Any,
                .foregroundColor: MarkdownHighlighter.defaultColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        markedTextLayer.string = nil
        markedTextLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let textSize = attributed.size()
        markedTextLayer.frame = bounds
        rebuildMarkedTextGlyphLayers(
            markedRange: markedRange,
            for: markedString,
            font: font,
            textView: textView,
            layoutManager: layoutManager,
            textContainer: textContainer,
            visibleRect: clipView.documentVisibleRect,
            baseY: bounds.height - textRect.maxY,
            textHeight: max(textSize.height, textRect.height),
            contentsScale: markedTextLayer.contentsScale
        )
        markedTextLayer.isHidden = false
        invalidateCachedGlyphs()
    }

    private func rebuildMarkedTextGlyphLayers(
        markedRange: NSRange,
        for text: String,
        font: NSFont,
        textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        visibleRect: CGRect,
        baseY: CGFloat,
        textHeight: CGFloat,
        contentsScale: CGFloat
    ) {
        markedTextGlyphLayers.forEach { $0.removeFromSuperlayer() }
        markedTextGlyphLayers.removeAll(keepingCapacity: false)

        let nsString = text as NSString
        var location = markedRange.location
        let end = markedRange.location + nsString.length
        while location < end {
            let localIndex = location - markedRange.location
            let localRange = nsString.rangeOfComposedCharacterSequence(at: localIndex)
            let range = NSRange(location: markedRange.location + localRange.location, length: localRange.length)
            let character = nsString.substring(with: localRange)
            defer { location = range.location + range.length }
            guard !character.unicodeScalars.allSatisfy({ $0.value <= 0x20 }),
                  let glyph = renderer.glyphAtlas.glyphInfo(for: character.unicodeScalars.first?.value ?? 0) else {
                continue
            }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            guard !rect.isEmpty else { continue }
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
            rect.origin.x -= visibleRect.origin.x
            rect.origin.y -= visibleRect.origin.y

            let markedFgColor = NSColor(calibratedWhite: 1.0, alpha: 0.55)
            let attributed = NSAttributedString(
                string: character,
                attributes: [
                    .font: font,
                    .foregroundColor: markedFgColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: markedFgColor
                ]
            )
            let glyphWidth = max(CGFloat(glyph.pixelWidth) / renderer.glyphAtlas.scaleFactor, 1)
            let glyphLayer = CATextLayer()
            glyphLayer.contentsScale = contentsScale
            glyphLayer.alignmentMode = .left
            glyphLayer.string = attributed
            glyphLayer.frame = NSRect(
                x: rect.origin.x + (CGFloat(glyph.cellOffsetX) / renderer.glyphAtlas.scaleFactor),
                y: baseY,
                width: glyphWidth,
                height: textHeight
            )
            markedTextLayer?.addSublayer(glyphLayer)
            markedTextGlyphLayers.append(glyphLayer)
        }
    }

    private func invalidateCachedGlyphs() {
        lastRenderedCharacterRange = NSRange(location: NSNotFound, length: 0)
        lastRenderedDocumentLength = -1
        lastRenderedBounds = .null
        lastRenderedScaleFactor = 0
    }

    private func appendGlyphVertices(
        from nsString: NSString,
        characterRange: NSRange,
        textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        visibleRect: NSRect,
        scaleFactor: Float,
        into vertices: inout [Float]
    ) {
        guard characterRange.length > 0 else { return }
        guard let textStorage = textView.textStorage else { return }
        var location = characterRange.location
        let end = NSMaxRange(characterRange)
        while location < end {
            let substringRange = nsString.rangeOfComposedCharacterSequence(at: location)
            let substring = nsString.substring(with: substringRange)
            defer { location = NSMaxRange(substringRange) }
            if shouldMaskGlyph(in: substringRange, textView: textView) {
                continue
            }
            guard substring != "\n",
                  let glyph = renderer.glyphAtlas.glyphInfo(for: substring.unicodeScalars.first?.value ?? 0),
                  glyph.textureW > 0 else {
                continue
            }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: substringRange, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            guard !rect.isEmpty else { continue }
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
            rect.origin.x -= visibleRect.origin.x
            rect.origin.y -= visibleRect.origin.y

            let color = (textStorage.attribute(.foregroundColor, at: substringRange.location, effectiveRange: nil) as? NSColor) ??
                MarkdownHighlighter.defaultColor
            let rgba = floatRGBA(for: color)
            let glyphWidth = max(Float(glyph.pixelWidth), 1)
            let glyphHeight = max(Float(glyph.pixelHeight), 1)
            let glyphX = (Float(rect.origin.x) * scaleFactor) + glyph.cellOffsetX
            let glyphY = (Float(rect.maxY) * scaleFactor) - glyphHeight
            addQuad(
                to: &vertices,
                x: glyphX,
                y: glyphY,
                w: glyphWidth,
                h: glyphHeight,
                tx: glyph.textureX,
                ty: glyph.textureY,
                tw: glyph.textureW,
                th: glyph.textureH,
                fg: rgba,
                bg: (0, 0, 0, 0)
            )
        }
    }

    private func appendPreviewVertices(scaleFactor: Float, now: CFTimeInterval, into vertices: inout [Float]) {
        for preview in previews {
            let progress = max(0.0, min(1.0, (now - preview.startedAt) / preview.duration))
            let alpha: Float
            switch preview.kind {
            case .fadeIn:
                let delayedProgress = pow(progress, 2.1)
                let smoothedProgress = delayedProgress * delayedProgress * (3.0 - 2.0 * delayedProgress)
                alpha = Float(0.02 + 0.98 * smoothedProgress)
            case .fadeOut:
                let easedProgress = progress * progress * (3.0 - 2.0 * progress)
                alpha = Float(0.4 * (1.0 - easedProgress))
            }
            var x = Float(preview.rect.origin.x) * scaleFactor
            let baselineYOffset: Float
            switch preview.kind {
            case .fadeIn:
                baselineYOffset = 0
            case .fadeOut:
                baselineYOffset = Float(20.0 * (progress * progress * (3.0 - 2.0 * progress)))
            }
            let color = floatRGBA(for: preview.color, alphaMultiplier: alpha)
            for scalar in preview.text.unicodeScalars {
                guard let glyph = renderer.glyphAtlas.glyphInfo(for: scalar.value),
                      glyph.textureW > 0 else {
                    x += Float(max(CharacterWidth.width(of: scalar.value), 1)) * Float(preview.rect.height)
                    continue
                }
                let glyphWidth = max(Float(glyph.pixelWidth), 1)
                let glyphHeight = max(Float(glyph.pixelHeight), 1)
                let glyphY = ((Float(preview.rect.maxY) + baselineYOffset) * scaleFactor) - glyphHeight
                let advance = max(Float(preview.rect.width) / Float(max(preview.text.count, 1)), Float(glyph.pixelWidth) / max(scaleFactor, 1))
                addQuad(
                    to: &vertices,
                    x: x + glyph.cellOffsetX,
                    y: glyphY,
                    w: glyphWidth,
                    h: glyphHeight,
                    tx: glyph.textureX,
                    ty: glyph.textureY,
                    tw: glyph.textureW,
                    th: glyph.textureH,
                    fg: color,
                    bg: (0, 0, 0, 0)
                )
                x += advance * scaleFactor
            }
        }
    }

    private func shouldMaskGlyph(in characterRange: NSRange, textView: NSTextView) -> Bool {
        let previewMasked = previews.contains { preview in
            guard let maskedRange = preview.maskedCharacterRange else { return false }
            return NSIntersectionRange(maskedRange, characterRange).length > 0
        }
        if previewMasked {
            return true
        }
        let markedRange = markedRange(for: textView)
        return markedRange.location != NSNotFound && NSIntersectionRange(markedRange, characterRange).length > 0
    }

    private func markedRange(for textView: NSTextView) -> NSRange {
        if let markdownTextView = textView as? MarkdownInputTextView {
            return markdownTextView.renderMarkedRange
        }
        return textView.markedRange()
    }

    private func markedAttributedString(for textView: NSTextView) -> NSAttributedString? {
        (textView as? MarkdownInputTextView)?.renderMarkedText
    }

    private func expandedVisibleRect(
        visibleRect: CGRect,
        textView: NSTextView,
        layoutManager: NSLayoutManager
    ) -> CGRect {
        let lineHeight = max(textView.font?.boundingRectForFont.height ?? 0, layoutManager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 13)))
        let overscan = lineHeight * PerformancePolicy.lineOverscanCount
        return visibleRect.insetBy(dx: 0, dy: -overscan)
    }

    private func updateVertexBuffer(_ existing: MTLBuffer?, floats: [Float]) -> MTLBuffer? {
        let requiredLength = floats.count * MemoryLayout<Float>.size
        guard requiredLength > 0 else {
            glyphBuffer = nil
            return nil
        }
        let boundedHeadroom = max(
            Int(Double(requiredLength) * PerformancePolicy.boundedHeadroomMultiplier),
            requiredLength + PerformancePolicy.boundedHeadroomFloor
        )
        let targetLength = max(requiredLength, boundedHeadroom)
        let buffer: MTLBuffer
        if let existing, existing.length >= requiredLength, existing.length <= max(targetLength, PerformancePolicy.largePayloadThreshold) {
            buffer = existing
        } else {
            guard let newBuffer = renderer.device.makeBuffer(length: targetLength, options: .storageModeShared) else {
                return nil
            }
            buffer = newBuffer
        }
        memcpy(buffer.contents(), floats, requiredLength)
        glyphBuffer = buffer
        return buffer
    }

    private func floatRGBA(for color: NSColor, alphaMultiplier: Float = 1.0) -> (Float, Float, Float, Float) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return (
            Float(rgb.redComponent),
            Float(rgb.greenComponent),
            Float(rgb.blueComponent),
            Float(rgb.alphaComponent) * alphaMultiplier
        )
    }

    private func addQuad(
        to vertices: inout [Float],
        x: Float,
        y: Float,
        w: Float,
        h: Float,
        tx: Float,
        ty: Float,
        tw: Float,
        th: Float,
        fg: (Float, Float, Float, Float),
        bg: (Float, Float, Float, Float)
    ) {
        let x0 = x
        let y0 = y
        let x1 = x + w
        let y1 = y + h
        let u0 = tx
        let v0 = ty
        let u1 = tx + tw
        let v1 = ty + th

        vertices.append(contentsOf: [x0, y0, u0, v0, fg.0, fg.1, fg.2, fg.3, bg.0, bg.1, bg.2, bg.3])
        vertices.append(contentsOf: [x1, y0, u1, v0, fg.0, fg.1, fg.2, fg.3, bg.0, bg.1, bg.2, bg.3])
        vertices.append(contentsOf: [x0, y1, u0, v1, fg.0, fg.1, fg.2, fg.3, bg.0, bg.1, bg.2, bg.3])
        vertices.append(contentsOf: [x1, y0, u1, v0, fg.0, fg.1, fg.2, fg.3, bg.0, bg.1, bg.2, bg.3])
        vertices.append(contentsOf: [x1, y1, u1, v1, fg.0, fg.1, fg.2, fg.3, bg.0, bg.1, bg.2, bg.3])
        vertices.append(contentsOf: [x0, y1, u0, v1, fg.0, fg.1, fg.2, fg.3, bg.0, bg.1, bg.2, bg.3])
    }
}

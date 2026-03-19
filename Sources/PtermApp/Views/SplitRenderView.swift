import AppKit
import MetalKit

/// A single MTKView overlay that renders all split-view terminals in one render pass.
///
/// macOS Window Server does not reliably composite multiple CAMetalLayers in a single
/// window — only the first/focused layer renders correctly. This view solves that by
/// rendering all terminal cells into a single Metal drawable using vertex offsets and
/// scissor rects, the same proven approach used by IntegratedView for thumbnails.
///
/// Event handling (keyboard, mouse, IME) remains on the individual TerminalViews
/// underneath. This view passes all hit-test events through (hitTest returns nil).
final class SplitRenderView: MTKView {
    private struct InlineImageLayerID {
        let ownerID: UUID
        let index: Int
    }
    /// Reference to a terminal cell in the split grid.
    /// Holds a weak reference to TerminalView so live state (selection, border) is read each frame.
    struct CellRef {
        weak var terminalView: TerminalView?
        let controller: TerminalController
        let frame: NSRect
    }

    private let renderer: MetalRenderer
    var cellRefs: [CellRef] = []
    /// Closure to compute border config for a TerminalView each frame.
    var borderConfigProvider: ((TerminalView) -> MetalRenderer.BorderConfig?)?
    var headerOverlayConfigProvider: ((TerminalController) -> MetalRenderer.HeaderOverlayConfig?)?
    var hasActiveOutput: Bool = false {
        didSet {
            guard hasActiveOutput != oldValue else { return }
            updateOutputPulseTimer()
            requestRender()
        }
    }
    var outputFrameThrottlingMode: OutputFrameThrottlingMode = TextInteractionConfiguration.default.outputFrameThrottlingMode {
        didSet {
            guard outputFrameThrottlingMode != oldValue else { return }
            updateOutputPulseTimer()
            requestRender()
        }
    }
    private var viewIsOpaque = false
    private var idleBufferReleaseTimer: Timer?
    private var outputPulseTimer: Timer?
    private var inlineImageLayers: [String: CALayer] = [:]
    private var inlineImageLayerIDs: [String: InlineImageLayerID] = [:]

    var debugHasOutputPulseTimer: Bool { outputPulseTimer != nil }
    var debugInlineImageLayerCount: Int { inlineImageLayers.count }
    func debugInlineImageLayerFrames() -> [CGRect] {
        inlineImageLayers.values.map(\.frame).sorted { lhs, rhs in
            if lhs.minY == rhs.minY { return lhs.minX < rhs.minX }
            return lhs.minY < rhs.minY
        }
    }

    init(frame: NSRect, renderer: MetalRenderer) {
        self.renderer = renderer
        super.init(frame: frame, device: renderer.device)

        self.colorPixelFormat = MetalRenderer.renderTargetPixelFormat
        self.clearColor = renderer.terminalClearColor
        self.framebufferOnly = true
        self.isPaused = true
        self.enableSetNeedsDisplay = true
        self.preferredFramesPerSecond = 30
        self.wantsLayer = true
        applyRenderTargetColorSpace()
        updateOpacityMode()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isOpaque: Bool { viewIsOpaque }

    deinit {
        idleBufferReleaseTimer?.invalidate()
        outputPulseTimer?.invalidate()
        clearInlineImageLayers()
        renderer.removeBuffers(for: self)
    }

    /// Pass all events through to the TerminalViews underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var acceptsFirstResponder: Bool { false }

    /// Detect backing scale factor changes (moving between Retina/non-Retina displays).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncScaleFactor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncScaleFactor()
    }

    func syncScaleFactorIfNeeded() {
        syncScaleFactor()
    }

    func applyAppearanceSettings() {
        clearColor = renderer.terminalClearColor
        updateOpacityMode()
        setNeedsDisplay(bounds)
    }

    func requestRender() {
        idleBufferReleaseTimer?.invalidate()
        idleBufferReleaseTimer = nil
        ensureDrawableStorageAllocatedIfNeeded()
        setNeedsDisplay(bounds)
        scheduleIdleBufferRelease()
    }

    private func updateOutputPulseTimer() {
        outputPulseTimer?.invalidate()
        outputPulseTimer = nil
        guard hasActiveOutput else { return }
        let configuredCap = max(outputFrameThrottlingMode.preferredOutputFPSCap, 1)
        let screenCap = window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 0
        let effectiveCap = screenCap > 0 ? min(configuredCap, screenCap) : configuredCap
        let floorInterval = 1.0 / Double(max(effectiveCap, 1))
        let interval = max(floorInterval, 0.25 / outputFrameThrottlingMode.redrawCadenceCoefficient)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.requestRender()
        }
        RunLoop.main.add(timer, forMode: .common)
        outputPulseTimer = timer
    }

    private func scheduleIdleBufferRelease() {
        idleBufferReleaseTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.releaseIdleReusableBuffersNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleBufferReleaseTimer = timer
    }

    private func releaseIdleReusableBuffersNow() {
        renderer.releaseSplitBuffers(for: self)
        _ = renderer.compactIdleGlyphAtlas()
        drawableSize = .zero
    }

    private func clearInlineImageLayers() {
        inlineImageLayers.values.forEach { $0.removeFromSuperlayer() }
        inlineImageLayers.removeAll(keepingCapacity: false)
        inlineImageLayerIDs.removeAll(keepingCapacity: false)
    }

    func pruneInlineImageResources(ownerID: UUID, retaining liveIndices: Set<Int>) {
        let staleKeys = inlineImageLayerIDs.compactMap { key, layerID -> String? in
            guard layerID.ownerID == ownerID, !liveIndices.contains(layerID.index) else { return nil }
            return key
        }
        guard !staleKeys.isEmpty else { return }
        for key in staleKeys {
            inlineImageLayers[key]?.removeFromSuperlayer()
            inlineImageLayers.removeValue(forKey: key)
            inlineImageLayerIDs.removeValue(forKey: key)
        }
    }

    private func updateInlineImageLayers(using snapshots: [(cellRect: NSRect, snapshot: TerminalController.RenderSnapshot)]) {
        guard let hostLayer = layer else {
            clearInlineImageLayers()
            return
        }

        var activeKeys = Set<String>()
        for item in snapshots {
            for placement in TerminalInlineImageSupport.detectPlacements(in: item.snapshot) {
                guard let ownerID = placement.ownerID,
                      let registeredImage = PastedImageRegistry.shared.registeredImage(ownerID: ownerID, forPlaceholderIndex: placement.index),
                      let cgImage = TerminalInlineImageSupport.cgImage(for: registeredImage) else {
                    continue
                }

                let key = "\(ObjectIdentifier(hostLayer).hashValue)-\(ownerID.uuidString)-\(placement.index)-\(Int(item.cellRect.origin.x))-\(Int(item.cellRect.origin.y))"
                activeKeys.insert(key)
                let frame = TerminalInlineImageSupport.frame(
                    for: placement,
                    registeredImage: registeredImage,
                    gridPadding: renderer.gridPadding,
                    cellWidth: renderer.glyphAtlas.cellWidth,
                    cellHeight: renderer.glyphAtlas.cellHeight,
                    viewHeight: item.cellRect.height,
                    offsetX: item.cellRect.origin.x,
                    offsetY: item.cellRect.origin.y
                )
                let imageLayer = inlineImageLayers[key] ?? {
                    let layer = CALayer()
                    layer.contentsGravity = .resizeAspect
                    layer.masksToBounds = true
                    layer.backgroundColor = NSColor.black.cgColor
                    hostLayer.addSublayer(layer)
                    inlineImageLayers[key] = layer
                    inlineImageLayerIDs[key] = InlineImageLayerID(ownerID: ownerID, index: placement.index)
                    return layer
                }()
                imageLayer.frame = frame
                imageLayer.contents = cgImage
                imageLayer.isHidden = false
            }
        }

        let staleKeys = inlineImageLayers.keys.filter { !activeKeys.contains($0) }
        for key in staleKeys {
            guard let layer = inlineImageLayers[key] else { continue }
            layer.removeFromSuperlayer()
            inlineImageLayers.removeValue(forKey: key)
            inlineImageLayerIDs.removeValue(forKey: key)
        }
    }

    func debugReleaseIdleBuffersNow() {
        releaseIdleReusableBuffersNow()
    }

    func debugRefreshInlineImagesForTesting() {
        let snapshots = cellRefs.map { ref in
            (cellRect: ref.frame, snapshot: ref.controller.captureRenderSnapshot())
        }
        updateInlineImageLayers(using: snapshots)
    }

    func debugRenderFrameToTextureForTesting(_ texture: MTLTexture) {
        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = renderer.terminalClearColor

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let viewportSize = SIMD2<Float>(Float(texture.width), Float(texture.height))
        let scaleFactor = Float(renderer.glyphAtlas.scaleFactor)
        var renderedSnapshots: [(cellRect: NSRect, snapshot: TerminalController.RenderSnapshot)] = []
        renderedSnapshots.reserveCapacity(cellRefs.count)
        for ref in cellRefs {
            guard let terminalView = ref.terminalView else { continue }
            let selection = terminalView.selection
            let border = borderConfigProvider?(terminalView)
            // Freeze each cell's visible terminal state before the expensive
            // shared render pass so PTY writers are not blocked by vertex work.
            let snapshot = ref.controller.captureRenderSnapshot()
            renderedSnapshots.append((cellRect: ref.frame, snapshot: snapshot))
            renderer.renderSplitCell(
                snapshot: snapshot,
                selection: selection,
                borderConfig: border,
                transientTextOverlays: [],
                suppressCursorBlink: false,
                encoder: encoder,
                viewportSize: viewportSize,
                cellRect: ref.frame,
                scaleFactor: scaleFactor,
                in: self
            )
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func scrubPresentedDrawableForRemoval() {
        ensureDrawableStorageAllocatedIfNeeded()
        guard let metalLayer = layer as? CAMetalLayer,
              let drawable = metalLayer.nextDrawable() else {
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "SplitRenderViewScrubDrawable"
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.label = "SplitRenderViewScrubDrawableEncoder"
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func releaseInactiveRenderingResourcesNow() {
        idleBufferReleaseTimer?.invalidate()
        idleBufferReleaseTimer = nil
        outputPulseTimer?.invalidate()
        outputPulseTimer = nil
        renderer.releaseSplitBuffers(for: self)
        _ = renderer.compactIdleGlyphAtlas(maximumInactiveGenerations: 0)
        drawableSize = .zero
    }

    func compactForMemoryPressureNow() {
        idleBufferReleaseTimer?.invalidate()
        idleBufferReleaseTimer = nil
        outputPulseTimer?.invalidate()
        outputPulseTimer = nil
        renderer.releaseSplitBuffers(for: self)
        _ = renderer.compactIdleGlyphAtlas(maximumInactiveGenerations: 0)
    }

    @discardableResult
    private func syncDrawableSizeToBoundsIfNeeded() -> Bool {
        let newScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let expectedSize = CGSize(width: bounds.width * newScale, height: bounds.height * newScale)
        guard expectedSize.width > 0, expectedSize.height > 0 else { return false }
        guard abs(drawableSize.width - expectedSize.width) > 1 ||
                abs(drawableSize.height - expectedSize.height) > 1 else {
            return false
        }
        drawableSize = expectedSize
        return true
    }

    private func ensureDrawableStorageAllocatedIfNeeded() {
        _ = syncDrawableSizeToBoundsIfNeeded()
    }

    private func syncScaleFactor() {
        let newScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.contentsScale = newScale
        applyRenderTargetColorSpace()
        if newScale != renderer.glyphAtlas.scaleFactor {
            renderer.glyphAtlas.updateScaleFactor(newScale)
        }
        _ = syncDrawableSizeToBoundsIfNeeded()
        setNeedsDisplay(bounds)
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

    private func updateOpacityMode() {
        viewIsOpaque = clearColor.alpha >= 0.999
        layer?.isOpaque = viewIsOpaque
        applyRenderTargetColorSpace()
    }

    private func applyRenderTargetColorSpace() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        metalLayer.colorspace = MetalRenderer.renderTargetColorSpace
        metalLayer.pixelFormat = MetalRenderer.renderTargetPixelFormat
        metalLayer.isOpaque = viewIsOpaque
        if #available(macOS 10.13.2, *) {
            metalLayer.maximumDrawableCount = 3
        }
        metalLayer.displaySyncEnabled = false
    }
}

// MARK: - MTKViewDelegate

extension SplitRenderView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // No-op: terminal sizes are managed by the TerminalViews.
    }

    func draw(in view: MTKView) {
        idleBufferReleaseTimer?.invalidate()
        idleBufferReleaseTimer = nil
        guard !cellRefs.isEmpty,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            return
        }
        RenderFPSMonitor.shared.recordFrame()

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = renderer.terminalClearColor

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor) else {
            return
        }

        let drawableSize = view.drawableSize
        let viewportSize = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        let sf = Float(renderer.glyphAtlas.scaleFactor)

        let viewHeight = bounds.height

        for ref in cellRefs {
            // Read live state from TerminalView each frame
            let selection = ref.terminalView?.selection
            let border = ref.terminalView.flatMap { borderConfigProvider?($0) }
            let headerOverlay = headerOverlayConfigProvider?(ref.controller)
            let transientTextOverlays = ref.terminalView?.activeTransientTextOverlaysForRendering() ?? []
            let suppressCursorBlink =
                !transientTextOverlays.isEmpty ||
                ((ref.terminalView?.debugPendingCommittedTextIntentCount ?? 0) > 0) ||
                (ref.terminalView?.hasMarkedText() ?? false)

            // Convert from NSView coordinates (y=0 at bottom) to Metal coordinates (y=0 at top)
            let flippedRect = NSRect(
                x: ref.frame.origin.x,
                y: viewHeight - ref.frame.origin.y - ref.frame.height,
                width: ref.frame.width,
                height: ref.frame.height
            )

            // The snapshot must be captured before rendering so split terminals
            // all read coherent controller state without holding locks in Metal work.
            let snapshot = ref.controller.captureRenderSnapshot()
            renderer.renderSplitCell(
                snapshot: snapshot,
                selection: selection,
                borderConfig: border,
                headerOverlayConfig: headerOverlay,
                transientTextOverlays: transientTextOverlays,
                suppressCursorBlink: suppressCursorBlink,
                encoder: encoder,
                viewportSize: viewportSize,
                cellRect: flippedRect,
                scaleFactor: sf,
                in: view
            )
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        scheduleIdleBufferRelease()
    }
}

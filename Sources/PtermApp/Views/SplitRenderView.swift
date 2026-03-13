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
    var hasActiveOutput: Bool = false {
        didSet {
            guard hasActiveOutput != oldValue else { return }
            updateOutputPulseTimer()
            requestRender()
        }
    }
    private var viewIsOpaque = false
    private var idleBufferReleaseTimer: Timer?
    private var outputPulseTimer: Timer?

    var debugHasOutputPulseTimer: Bool { outputPulseTimer != nil }

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
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
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

    func debugReleaseIdleBuffersNow() {
        releaseIdleReusableBuffersNow()
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

    private func ensureDrawableStorageAllocatedIfNeeded() {
        guard drawableSize == .zero else { return }
        let newScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let expectedSize = CGSize(width: bounds.width * newScale, height: bounds.height * newScale)
        guard expectedSize.width > 0, expectedSize.height > 0 else { return }
        drawableSize = expectedSize
    }

    private func syncScaleFactor() {
        let newScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.contentsScale = newScale
        applyRenderTargetColorSpace()
        if newScale != renderer.glyphAtlas.scaleFactor {
            renderer.glyphAtlas.updateScaleFactor(newScale)
        }
        let expectedSize = CGSize(width: bounds.width * newScale, height: bounds.height * newScale)
        if drawableSize != .zero,
           (abs(drawableSize.width - expectedSize.width) > 1 || abs(drawableSize.height - expectedSize.height) > 1) {
            drawableSize = expectedSize
        }
        setNeedsDisplay(bounds)
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
            metalLayer.maximumDrawableCount = 2
        }
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
            let transientTextOverlays = ref.terminalView?.activeCommittedTextPreviewOverlays() ?? []

            // Convert from NSView coordinates (y=0 at bottom) to Metal coordinates (y=0 at top)
            let flippedRect = NSRect(
                x: ref.frame.origin.x,
                y: viewHeight - ref.frame.origin.y - ref.frame.height,
                width: ref.frame.width,
                height: ref.frame.height
            )

            ref.controller.withViewport { model, scrollback, scrollOffset in
                renderer.renderSplitCell(
                    model: model,
                    scrollback: scrollback,
                    scrollOffset: scrollOffset,
                    selection: selection,
                    borderConfig: border,
                    transientTextOverlays: transientTextOverlays,
                    encoder: encoder,
                    viewportSize: viewportSize,
                    cellRect: flippedRect,
                    scaleFactor: sf,
                    in: view
                )
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        scheduleIdleBufferRelease()
    }
}

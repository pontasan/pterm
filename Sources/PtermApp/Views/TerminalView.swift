import AppKit
import Foundation
import ImageIO
import MetalKit
import QuartzCore

/// NSView subclass that hosts a Metal layer for terminal rendering.
///
/// Handles keyboard input, mouse events (text selection), scroll wheel
/// for scrollback navigation, and delegates rendering to the MetalRenderer.
/// Wrapped inside a TerminalScrollView for native macOS scrollbar behavior.
final class TerminalView: MTKView, NSTextInputClient {
    private struct PendingScrollSyncState {
        let scrollbackRowCount: Int
        let viewRows: Int
        let scrollOffset: Int
        let cellHeight: CGFloat
    }

    private enum PreviewPolicy {
        static let maxCommittedTextPreviewCount = 30
        static let pendingIntentTimeout: CFTimeInterval = 0.60
    }

    private enum ResizeNotificationMode {
        case immediateOnly
        case immediateAndDeferred
    }

    private struct MouseReportingState {
        let mode: TerminalModel.MouseReportingMode
        let protocolMode: TerminalModel.MouseProtocol
    }

    private struct CommittedTextPreview {
        enum Kind {
            case fadeIn
            case fadeOut
            /// Hold at full alpha — bridges marked-text-to-grid transition.
            case hold
        }

        let text: String
        let row: Int
        let col: Int
        let columnWidth: Int
        let cursorRow: Int?
        let cursorCol: Int?
        let startedAt: CFTimeInterval
        let duration: CFTimeInterval
        let kind: Kind
    }

    private struct RecentCommittedInsertion {
        let text: String
        let row: Int
        let col: Int
        let columnWidth: Int
    }

    /// Terminal controller for this view
    var terminalController: TerminalController? {
        willSet {
            guard terminalController !== newValue else { return }
            teardownController()
        }
        didSet {
            guard terminalController !== oldValue else { return }
            setupController()
        }
    }

    /// Metal renderer
    var renderer: MetalRenderer?
    var shortcutConfiguration: ShortcutConfiguration = .default
    var outputConfirmedInputAnimationsEnabled: Bool = TextInteractionConfiguration.default.outputConfirmedInputAnimation {
        didSet {
            guard !outputConfirmedInputAnimationsEnabled else { return }
            pendingCommittedTextIntents.removeAll(keepingCapacity: false)
        }
    }
    private var selectAllActive = false

    /// Keyboard handler
    private var keyboardHandler: KeyboardHandler?
    var inputFeedbackPlayer: TypewriterKeyClicking = TypewriterKeyClickPlayerFactory.defaultPlayer {
        didSet {
            keyboardHandler = nil
        }
    }
    var typewriterSoundEnabled: Bool = TextInteractionConfiguration.default.typewriterSoundEnabled {
        didSet {
            keyboardHandler = nil
        }
    }
    var outputFrameThrottlingMode: OutputFrameThrottlingMode = TextInteractionConfiguration.default.outputFrameThrottlingMode {
        didSet {
            guard outputFrameThrottlingMode != oldValue else { return }
            requestDisplayUpdate()
            updateOutputPulseTimer()
        }
    }

    /// Callback when user requests to go back to integrated view
    var onBackToIntegrated: (() -> Void)?
    var onBecameFirstResponder: (() -> Void)?
    /// Callback when user Cmd+clicks (maximize/restore in split view)
    var onCmdClick: (() -> Void)?
    /// Callback when user Shift+Cmd+clicks in split view to stage terminals for reselection.
    var onShiftCommandClick: (() -> Void)?
    /// Tooltip shown when hovering over this terminal (e.g., Cmd+click hint).
    var cmdClickTooltip: String? {
        didSet { toolTip = cmdClickTooltip }
    }
    /// Resolves terminal `[Image #x]` placeholders to locally stored pasted images.
    var imagePreviewURLProvider: ((UUID, Int) -> URL?)?

    /// When true, rendering is demand-driven (only on model changes) instead of 60fps continuous.
    /// Used in split view to avoid overwhelming GPU with many independent display links.
    var demandDrivenRendering: Bool = false {
        didSet {
            isPaused = demandDrivenRendering
            enableSetNeedsDisplay = demandDrivenRendering
            updateCursorBlinkTimer()
            if demandDrivenRendering {
                requestDisplayUpdate()
            }
        }
    }

    /// When true, this view's own draw() does nothing. An external SplitRenderView
    /// handles all rendering into a single MTKView to avoid macOS CAMetalLayer
    /// compositing issues with multiple Metal layers in one window.
    private var splitRenderingSuppressed = false {
        didSet {
            guard splitRenderingSuppressed != oldValue else { return }
            refreshEffectiveRenderingSuppression()
        }
    }
    private var terminalRenderingSuppressed = false {
        didSet {
            guard terminalRenderingSuppressed != oldValue else { return }
            refreshEffectiveRenderingSuppression()
        }
    }
    private(set) var renderingSuppressed: Bool = false {
        didSet {
            guard renderingSuppressed != oldValue else { return }
            updateSuppressedRenderingState()
        }
    }

    /// Border configuration for split-view focus indication (drawn within Metal pipeline).
    var borderConfig: MetalRenderer.BorderConfig?
    var isOutputActive: Bool = false {
        didSet {
            guard isOutputActive != oldValue else { return }
            updateOutputPulseTimer()
            requestDisplayUpdate()
        }
    }
    private var commandModifierActive = false {
        didSet {
            guard commandModifierActive != oldValue else { return }
            requestDisplayUpdate()
        }
    }
    private var commandIdentityHeaderVisible = false {
        didSet {
            guard commandIdentityHeaderVisible != oldValue else { return }
            requestDisplayUpdate()
        }
    }
    private var suppressCommandIdentityHeaderUntilCommandRelease = false {
        didSet {
            guard suppressCommandIdentityHeaderUntilCommandRelease != oldValue else { return }
            syncSplitContainerCommandIdentityHeaderVisibility()
            requestDisplayUpdate()
        }
    }

    /// Current text selection (nil = no selection)
    private(set) var selection: TerminalSelection? {
        didSet {
            requestDisplayUpdate()
        }
    }

    /// Click count tracker for double/triple click detection
    private var clickCount: Int = 0
    private var lastClickTime: TimeInterval = 0
    private var lastClickPosition: GridPosition?
    private static let multiClickInterval: TimeInterval = 0.3

    /// Accumulated scroll delta for smooth (trackpad) scrolling.
    /// We accumulate fractional lines until a full line is reached.
    private var scrollAccumulator: CGFloat = 0
    private var searchMatches: [TerminalController.SearchMatch] = []
    private var currentSearchIndex: Int?
    private var selectionBeforeSearch: TerminalSelection?
    private var trackingArea: NSTrackingArea?
    private var pressedMouseButton: Int?
    private var windowObservers: [NSObjectProtocol] = []
    private var cursorBlinkTimer: Timer?
    private var outputPulseTimer: Timer?
    private var committedTextPreviewTimer: Timer?
    private var pendingIntentResolutionTimer: Timer?
    private var idleBufferReleaseTimer: Timer?
    private var deferredResizeNotificationWorkItems: [DispatchWorkItem] = []
    private var markedTextLayer: CATextLayer?
    private var markedTextGlyphFrames: [CGRect] = []
    private var markedTextStorage: NSMutableAttributedString?
    private var markedTextSelection = NSRange(location: NSNotFound, length: 0)
    private var deferredMarkedTextOverlayStorage: NSMutableAttributedString?
    private var deferredMarkedTextOverlaySelection = NSRange(location: NSNotFound, length: 0)
    private var deferredMarkedTextOverlayClearWorkItem: DispatchWorkItem?
    private var markedTextPreviewStartedAt: CFTimeInterval?
    private var lastMarkedTextForAnimation: String?
    private var pendingMarkedTextContinuation: String?
    private var markedTextAnimatedSegment: (text: String, colOffset: Int, startedAt: CFTimeInterval)?
    private var committedTextPreviews: [CommittedTextPreview] = []
    private var recentCommittedInsertions: [RecentCommittedInsertion] = []
    private var pendingCommittedTextIntents: [CommittedTextAnimationIntent] = []
    private var pendingTextInputHandled = false
    private var viewIsOpaque = false
    private var debugSuppressInterpretKeyEvents = false

    /// URL hover state for Cmd+mouseover visual feedback
    private var hoveredLinkRange: (row: Int, startCol: Int, endCol: Int)?
    private var hoveredImagePlaceholder: TerminalController.DetectedImagePlaceholder?
    private var imagePreviewWindow: NSWindow?
    private var imagePreviewView: NSImageView?
    private var inlineImageLayers: [Int: CALayer] = [:]
    private var lastDrawnRenderContentVersion: UInt64 = 0
    private var displayUpdateScheduled = false
    private var scrollerSyncScheduled = false
    private var pendingScrollSyncState: PendingScrollSyncState?
    private var deferredDisplayUpdateWorkItem: DispatchWorkItem?
    private var lastDisplaySubmissionTime: CFTimeInterval = 0

    var hasActiveImagePreviewWindow: Bool { imagePreviewWindow != nil }
    var debugInlineImageLayerCount: Int { inlineImageLayers.count }
    func debugInlineImageLayerFrames() -> [CGRect] {
        inlineImageLayers.values.map(\.frame).sorted { lhs, rhs in
            if lhs.minY == rhs.minY { return lhs.minX < rhs.minX }
            return lhs.minY < rhs.minY
        }
    }
    var debugHasKeyboardHandler: Bool { keyboardHandler != nil }
    var debugHasMarkedTextStorage: Bool { markedTextStorage != nil }
    var debugMarkedTextLayerForTesting: CATextLayer? { markedTextLayer }
    var debugMarkedTextGlyphFramesForTesting: [CGRect] {
        markedTextGlyphFrames.sorted { lhs, rhs in
            if lhs.minY == rhs.minY { return lhs.minX < rhs.minX }
            return lhs.minY < rhs.minY
        }
    }
    var debugHasOutputPulseTimer: Bool { outputPulseTimer != nil }
    var debugEffectiveDisplayUpdateFPSForTesting: Int { effectiveDisplayUpdateFPS() }
    var debugHasCommittedTextPreview: Bool { !activeCommittedTextPreviewOverlays().isEmpty }
    var debugCommittedTextPreviewCount: Int { committedTextPreviews.count }
    var debugCommittedTextPreviewAlphas: [Float] { activeCommittedTextPreviewOverlays().map(\.alpha) }
    var debugCommittedTextPreviewKinds: [String] {
        committedTextPreviews.map {
            switch $0.kind {
            case .fadeIn: return "fadeIn"
            case .fadeOut: return "fadeOut"
            case .hold: return "hold"
            }
        }
    }
    var debugCommittedTextPreviewTexts: [String] { committedTextPreviews.map(\.text) }
    var debugPendingCommittedTextIntentCount: Int { pendingCommittedTextIntents.count }
    var debugHasPendingIntentResolutionTimer: Bool { pendingIntentResolutionTimer != nil }
    var debugLastPendingCommittedTextIntentText: String? { pendingCommittedTextIntents.last?.text }
    var debugMarkedTextTransientOverlayCount: Int { activeMarkedTextTransientOverlays().count }
    var debugMarkedTextTransientOverlayAlphas: [Float] { activeMarkedTextTransientOverlays().map(\.alpha) }
    var debugMarkedTextTransientOverlayTexts: [String] { activeMarkedTextTransientOverlays().map(\.text) }
    var debugDeferredResizeNotificationCount: Int { deferredResizeNotificationWorkItems.count }
    var debugIsDisplayUpdateScheduledForTesting: Bool { displayUpdateScheduled }

    func setSplitRenderingSuppressed(_ suppressed: Bool) {
        splitRenderingSuppressed = suppressed
    }

    func setTerminalRenderingSuppressed(_ suppressed: Bool) {
        terminalRenderingSuppressed = suppressed
    }

    private func refreshEffectiveRenderingSuppression() {
        renderingSuppressed = splitRenderingSuppressed || terminalRenderingSuppressed
    }

    private func queueInputFeedbackIfEnabled() {
        guard typewriterSoundEnabled else { return }
        let player = inputFeedbackPlayer
        DispatchQueue.main.async {
            player.playKeystroke()
        }
    }

    func debugSetSelectionForTesting(_ sel: TerminalSelection?) {
        selection = sel
    }

    func debugSetSuppressInterpretKeyEvents(_ suppressed: Bool) {
        debugSuppressInterpretKeyEvents = suppressed
    }

    func debugInstallImagePreviewWindowForTesting() {
        guard imagePreviewWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let imageView = NSImageView(frame: window.frame)
        imagePreviewWindow = window
        imagePreviewView = imageView
    }

    func debugReleaseImagePreviewWindowNow() {
        hideImagePreview()
    }

    func debugRefreshInlineImagesForTesting() {
        guard let controller = terminalController else {
            clearInlineImageLayers()
            return
        }
        updateInlineImageLayers(with: controller.captureRenderSnapshot())
    }

    func debugRenderFrameToTextureForTesting(_ texture: MTLTexture) {
        guard let controller = terminalController,
              let renderer else { return }
        let transientTextOverlays = activeTransientTextOverlaysForRendering()
        let suppressCursorBlink =
            !transientTextOverlays.isEmpty || !pendingCommittedTextIntents.isEmpty || hasMarkedText()
        let snapshot = controller.captureRenderSnapshot()

        renderer.debugRenderToTextureForTesting(
            snapshot: snapshot,
            texture: texture,
            selection: selection,
            transientTextOverlays: transientTextOverlays,
            suppressCursorBlink: suppressCursorBlink
        )
    }

    func debugRenderedPNGDataForTesting() -> Data? {
        guard let renderer else { return nil }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let expectedSize = expectedDrawableSize(for: scale)
        let pixelWidth = max(Int(expectedSize.width.rounded(.up)), 1)
        let pixelHeight = max(Int(expectedSize.height.rounded(.up)), 1)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalRenderer.renderTargetPixelFormat,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else { return nil }

        debugRenderFrameToTextureForTesting(texture)

        let bytesPerRow = pixelWidth * 4
        var bgraBytes = [UInt8](repeating: 0, count: bytesPerRow * pixelHeight)
        texture.getBytes(
            &bgraBytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight),
            mipmapLevel: 0
        )

        var rgbaBytes = bgraBytes
        var index = 0
        while index < bgraBytes.count {
            rgbaBytes[index] = bgraBytes[index + 2]
            rgbaBytes[index + 1] = bgraBytes[index + 1]
            rgbaBytes[index + 2] = bgraBytes[index]
            // The render target is visually composited over the terminal's black
            // background in the app. Flatten the exported debug image the same way
            // so screenshot parity compares the actual visible result instead of
            // alpha-channel implementation details.
            rgbaBytes[index + 3] = 0xFF
            index += 4
        }

        let data = Data(rgbaBytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .png, properties: [:])
    }

    @discardableResult
    func handlePriorityInterruptShortcut() -> Bool {
        guard let controller = terminalController else { return false }
        if controller.withModel({ $0.kittyKeyboardProtocolEnabled }) {
            controller.sendInput("\u{1B}[99;5u")
            queueInputFeedbackIfEnabled()
            return true
        }
        controller.performInterrupt()
        queueInputFeedbackIfEnabled()
        return true
    }

    // MARK: - Initialization

    init(frame: NSRect, renderer: MetalRenderer) {
        self.renderer = renderer

        super.init(frame: frame, device: renderer.device)

        self.delegate = self
        self.preferredFramesPerSecond = 30
        self.colorPixelFormat = MetalRenderer.renderTargetPixelFormat
        self.clearColor = renderer.terminalClearColor
        self.framebufferOnly = true
        self.autoResizeDrawable = false
        self.isPaused = true
        self.enableSetNeedsDisplay = true
        self.registerForDraggedTypes([.fileURL])
        self.wantsLayer = true
        applyRenderTargetColorSpace()
        demandDrivenRendering = true
        updateOpacityMode()

        _ = self.becomeFirstResponder()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isOpaque: Bool { viewIsOpaque }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecameFirstResponder?()
            updateCursorBlinkTimer()
        }
        return accepted
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        for action in ShortcutAction.allCases {
            guard shortcutConfiguration.matches(action, event: event),
                  let selector = action.appDelegateSelector else {
                continue
            }
            if action == .backToIntegrated {
                onBackToIntegrated?()
                return true
            }
            return NSApp.sendAction(selector, to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Multi-Display Support

    /// Detect backing scale factor changes (moving between Retina/non-Retina displays).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncScaleFactor()
    }

    /// Also sync when the view moves to a new window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncScaleFactor()
        updateWindowObservers()
    }

    /// Public entry point for NSWindowDelegate to trigger scale sync.
    func syncScaleFactorIfNeeded() {
        syncScaleFactor()
    }

    func applyAppearanceSettings() {
        clearColor = renderer?.terminalClearColor ?? clearColor
        updateOpacityMode()
        requestDisplayUpdate()
        updateMarkedTextOverlay()
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

    private func expectedDrawableSize(for scale: CGFloat) -> CGSize {
        guard !renderingSuppressed, bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    @discardableResult
    private func syncDrawableSizeToBoundsIfNeeded() -> Bool {
        guard !renderingSuppressed else { return false }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let expectedSize = expectedDrawableSize(for: scale)
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

    private func updateSuppressedRenderingState() {
        guard let renderer else { return }
        idleBufferReleaseTimer?.invalidate()
        idleBufferReleaseTimer = nil
        if renderingSuppressed {
            cursorBlinkTimer?.invalidate()
            cursorBlinkTimer = nil
            outputPulseTimer?.invalidate()
            outputPulseTimer = nil
            pendingIntentResolutionTimer?.invalidate()
            pendingIntentResolutionTimer = nil
            cancelDeferredResizeNotifications()
            cancelDeferredDisplayUpdate()
            clearCommittedTextPreview()
            isPaused = true
            enableSetNeedsDisplay = false
            drawableSize = .zero
            renderer.removeBuffers(for: self)
            return
        }

        isPaused = demandDrivenRendering
        enableSetNeedsDisplay = demandDrivenRendering
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let expectedSize = expectedDrawableSize(for: scale)
        if abs(drawableSize.width - expectedSize.width) > 1 || abs(drawableSize.height - expectedSize.height) > 1 {
            drawableSize = expectedSize
        }
        syncScaleFactor()
        requestDisplayUpdate()
        updateCursorBlinkTimer()
        updateOutputPulseTimer()
    }

    /// Synchronize the glyph atlas scale factor with the current display.
    private func syncScaleFactor() {
        guard let renderer = renderer else { return }
        let newScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        applyRenderTargetColorSpace()
        if newScale != renderer.glyphAtlas.scaleFactor {
            renderer.glyphAtlas.updateScaleFactor(newScale)
            updateTerminalSize(notificationMode: .immediateAndDeferred)
        }
        let expectedSize = expectedDrawableSize(for: newScale)
        if abs(drawableSize.width - expectedSize.width) > 1 || abs(drawableSize.height - expectedSize.height) > 1 {
            drawableSize = expectedSize
        }
        updateMarkedTextOverlay()
        if !renderingSuppressed {
            requestDisplayUpdate()
        }
    }

    private func scheduleIdleBufferRelease() {
        guard demandDrivenRendering, !renderingSuppressed else { return }
        guard !isOutputActive else { return }
        guard idleBufferReleaseTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.idleBufferReleaseTimer = nil
            self.releaseIdleReusableBuffersNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleBufferReleaseTimer = timer
    }

    private func releaseIdleReusableBuffersNow() {
        guard demandDrivenRendering, !renderingSuppressed else { return }
        let isTransientTerminal = terminalController?.isTransient == true
        if isOutputActive || (!isTransientTerminal && window?.isKeyWindow == true && window?.firstResponder === self) {
            scheduleIdleBufferRelease()
            return
        }
        renderer?.releaseTerminalBuffers(for: self)
        _ = renderer?.compactIdleGlyphAtlas()
        keyboardHandler = nil
        guard cursorBlinkTimer == nil else { return }
        drawableSize = .zero
    }

    func debugReleaseIdleBuffersNow() {
        releaseIdleReusableBuffersNow()
    }

    func scrubPresentedDrawableForRemoval() {
        guard let renderer else { return }
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
        commandBuffer.label = "TerminalViewScrubDrawable"
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.label = "TerminalViewScrubDrawableEncoder"
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func releaseInactiveRenderingResourcesNow() {
        idleBufferReleaseTimer?.invalidate()
        idleBufferReleaseTimer = nil
        committedTextPreviewTimer?.invalidate()
        committedTextPreviewTimer = nil
        pendingIntentResolutionTimer?.invalidate()
        pendingIntentResolutionTimer = nil
        cancelDeferredResizeNotifications()
        cancelDeferredDisplayUpdate()
        renderer?.releaseTerminalBuffers(for: self)
        _ = renderer?.compactIdleGlyphAtlas(maximumInactiveGenerations: 0)
        keyboardHandler = nil
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        outputPulseTimer?.invalidate()
        outputPulseTimer = nil
        clearCommittedTextPreview()
        drawableSize = .zero
    }

    func detachControllerForPresentationTransition() {
        onBecameFirstResponder = nil
        onBackToIntegrated = nil
        onCmdClick = nil
        onShiftCommandClick = nil
        terminalController = nil
    }

    func compactForMemoryPressureNow() {
        idleBufferReleaseTimer?.invalidate()
        idleBufferReleaseTimer = nil
        renderer?.releaseTerminalBuffers(for: self)
        _ = renderer?.compactIdleGlyphAtlas(maximumInactiveGenerations: 0)
        keyboardHandler = nil
        clearCommittedTextPreview()
    }

    // MARK: - Setup

    private func teardownController() {
        cancelDeferredResizeNotifications()
        cancelDeferredDisplayUpdate()
        terminalController?.onNeedsDisplay = nil
        terminalController?.onRenderingSuppressedChange = nil
        keyboardHandler = nil
        clearInlineImageLayers()
    }

    private func setupController() {
        guard let controller = terminalController else { return }
        keyboardHandler = nil

        controller.onNeedsDisplay = { [weak self] in
            self?.resolvePendingCommittedTextIntentsIfNeeded()
            self?.requestDisplayUpdate()
            self?.updateMarkedTextOverlay()
        }
        controller.onRenderingSuppressedChange = { [weak self] suppressed in
            self?.setTerminalRenderingSuppressed(suppressed)
        }
        controller.notifyFocusChanged(window?.isKeyWindow == true)
        updateTerminalSize(notificationMode: .immediateOnly)
        updateCursorBlinkTimer()
        updateOutputPulseTimer()
        setTerminalRenderingSuppressed(controller.isRenderingSuppressed)
        // When a controller is assigned to a new view (e.g., returning to split view),
        // ensure we show the latest output, not stale scrollback position.
        controller.scrollToBottom()
    }

    deinit {
        cursorBlinkTimer?.invalidate()
        outputPulseTimer?.invalidate()
        committedTextPreviewTimer?.invalidate()
        pendingIntentResolutionTimer?.invalidate()
        idleBufferReleaseTimer?.invalidate()
        cancelDeferredResizeNotifications()
        cancelDeferredDisplayUpdate()
        removeWindowObservers()
        hideImagePreview()
        clearInlineImageLayers()
        renderer?.removeBuffers(for: self)
    }

    private func updateWindowObservers() {
        removeWindowObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.terminalController?.notifyFocusChanged(true)
                self?.updateCursorBlinkTimer()
            },
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.terminalController?.notifyFocusChanged(false)
                self?.updateCursorBlinkTimer()
            }
        ]
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        windowObservers.removeAll(keepingCapacity: true)
    }

    private func ensureKeyboardHandler() -> KeyboardHandler? {
        if let keyboardHandler {
            return keyboardHandler
        }
        guard let controller = terminalController else { return nil }
        let handler = KeyboardHandler(
            controller: controller,
            inputFeedbackPlayer: inputFeedbackPlayer,
            inputFeedbackEnabled: { [weak self] in self?.typewriterSoundEnabled ?? false }
        )
        keyboardHandler = handler
        return handler
    }

    private func configureMarkedTextLayer() {
        guard markedTextLayer == nil else { return }
        let textLayer = CATextLayer()
        textLayer.isHidden = true
        textLayer.alignmentMode = .left
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.addSublayer(textLayer)
        markedTextLayer = textLayer
    }

    private func destroyMarkedTextLayer() {
        markedTextGlyphFrames.removeAll(keepingCapacity: false)
        markedTextLayer?.removeFromSuperlayer()
        markedTextLayer = nil
    }

    private func cancelDeferredMarkedTextOverlayClear() {
        deferredMarkedTextOverlayClearWorkItem?.cancel()
        deferredMarkedTextOverlayClearWorkItem = nil
    }

    private func clearDeferredMarkedTextOverlay() {
        cancelDeferredMarkedTextOverlayClear()
        deferredMarkedTextOverlayStorage = nil
        deferredMarkedTextOverlaySelection = NSRange(location: NSNotFound, length: 0)
    }

    private func visibleMarkedTextStorage() -> NSMutableAttributedString? {
        if let markedTextStorage, !markedTextStorage.string.isEmpty {
            return markedTextStorage
        }
        if let deferredMarkedTextOverlayStorage, !deferredMarkedTextOverlayStorage.string.isEmpty {
            return deferredMarkedTextOverlayStorage
        }
        return nil
    }

    private func visibleMarkedTextSelection() -> NSRange {
        if let markedTextStorage, !markedTextStorage.string.isEmpty {
            return markedTextSelection
        }
        return deferredMarkedTextOverlaySelection
    }

    private func clearCommittedTextPreview() {
        committedTextPreviewTimer?.invalidate()
        committedTextPreviewTimer = nil
        pendingIntentResolutionTimer?.invalidate()
        pendingIntentResolutionTimer = nil
        committedTextPreviews.removeAll(keepingCapacity: false)
        recentCommittedInsertions.removeAll(keepingCapacity: false)
        pendingCommittedTextIntents.removeAll(keepingCapacity: false)
        clearDeferredMarkedTextOverlay()
        markedTextPreviewStartedAt = nil
        lastMarkedTextForAnimation = nil
        pendingMarkedTextContinuation = nil
        markedTextAnimatedSegment = nil
    }

    private func clearCommittedInputAnimationState() {
        committedTextPreviewTimer?.invalidate()
        committedTextPreviewTimer = nil
        pendingIntentResolutionTimer?.invalidate()
        pendingIntentResolutionTimer = nil
        committedTextPreviews.removeAll(keepingCapacity: false)
        pendingCommittedTextIntents.removeAll(keepingCapacity: false)
    }

    private func clearInlineImageLayers() {
        inlineImageLayers.values.forEach { $0.removeFromSuperlayer() }
        inlineImageLayers.removeAll(keepingCapacity: false)
    }

    func pruneInlineImageResources(ownerID: UUID, retaining liveIndices: Set<Int>) {
        guard terminalController?.id == ownerID else { return }

        if let hoveredImagePlaceholder,
           hoveredImagePlaceholder.ownerID == ownerID,
           !liveIndices.contains(hoveredImagePlaceholder.index) {
            hideImagePreview()
        }

        let staleIndices = inlineImageLayers.keys.filter { !liveIndices.contains($0) }
        guard !staleIndices.isEmpty else { return }
        for index in staleIndices {
            guard let layer = inlineImageLayers[index] else { continue }
            layer.removeFromSuperlayer()
            inlineImageLayers.removeValue(forKey: index)
        }
    }

    private func updateInlineImageLayers(with snapshot: TerminalController.RenderSnapshot) {
        guard imagePreviewURLProvider != nil,
              let renderer,
              let hostLayer = layer else {
            clearInlineImageLayers()
            return
        }

        let placements = TerminalInlineImageSupport.detectPlacements(in: snapshot)
        guard !placements.isEmpty else {
            clearInlineImageLayers()
            return
        }

        var activeIndices = Set<Int>()
        for placement in placements {
            guard let ownerID = placement.ownerID,
                  let registeredImage = PastedImageRegistry.shared.registeredImage(ownerID: ownerID, forPlaceholderIndex: placement.index),
                  let cgImage = TerminalInlineImageSupport.cgImage(for: registeredImage) else {
                continue
            }

            activeIndices.insert(placement.index)
            let frame = TerminalInlineImageSupport.frame(
                for: placement,
                registeredImage: registeredImage,
                gridPadding: renderer.gridPadding,
                cellWidth: renderer.glyphAtlas.cellWidth,
                cellHeight: renderer.glyphAtlas.cellHeight,
                viewHeight: bounds.height
            )
            let imageLayer = inlineImageLayers[placement.index] ?? {
                let layer = CALayer()
                layer.contentsGravity = .resizeAspect
                layer.masksToBounds = true
                layer.backgroundColor = NSColor.black.cgColor
                hostLayer.addSublayer(layer)
                inlineImageLayers[placement.index] = layer
                return layer
            }()
            imageLayer.frame = frame
            imageLayer.contents = cgImage
            imageLayer.isHidden = false
        }

        let staleIndices = inlineImageLayers.keys.filter { !activeIndices.contains($0) }
        for index in staleIndices {
            guard let layer = inlineImageLayers[index] else { continue }
            layer.removeFromSuperlayer()
            inlineImageLayers.removeValue(forKey: index)
        }
    }

    private func requestDisplayUpdate() {
        idleBufferReleaseTimer?.invalidate()
        idleBufferReleaseTimer = nil
        if renderingSuppressed,
           let splitContainer = enclosingScrollView?.superview as? SplitTerminalContainerView {
            splitContainer.requestRender()
            return
        }
        guard !displayUpdateScheduled else { return }
        let now = CACurrentMediaTime()
        let targetFPS = max(effectiveDisplayUpdateFPS(), 1)
        let minimumInterval = 1.0 / Double(targetFPS)
        let targetTime = max(now, lastDisplaySubmissionTime + minimumInterval)
        displayUpdateScheduled = true

        let scheduleDisplay = { [weak self] in
            guard let self else { return }
            self.deferredDisplayUpdateWorkItem = nil
            self.displayUpdateScheduled = false
            self.ensureDrawableStorageAllocatedIfNeeded()
            self.setNeedsDisplay(self.bounds)
        }

        if targetTime <= now + 0.0005 {
            cancelDeferredDisplayUpdate()
            scheduleDisplay()
            return
        }

        let workItem = DispatchWorkItem(block: scheduleDisplay)
        deferredDisplayUpdateWorkItem?.cancel()
        deferredDisplayUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + (targetTime - now), execute: workItem)
    }

    private func cancelDeferredDisplayUpdate() {
        deferredDisplayUpdateWorkItem?.cancel()
        deferredDisplayUpdateWorkItem = nil
        displayUpdateScheduled = false
    }

    private func effectiveDisplayUpdateFPS() -> Int {
        guard isOutputActive,
              pendingCommittedTextIntents.isEmpty,
              !hasMarkedText() else {
            return preferredFramesPerSecond
        }
        let baseFPS = terminalController?.isTransient == true ? 2.0 : 15.0
        return scaledOutputFPS(baseFPS: baseFPS)
    }

    private func scaledOutputFPS(baseFPS: Double) -> Int {
        let adjusted = baseFPS * outputFrameThrottlingMode.redrawCadenceCoefficient
        let capped = min(adjusted, Double(displayAwareOutputFPSCap()))
        return max(1, Int(capped.rounded()))
    }

    private func scaledOutputPulseInterval(baseInterval: TimeInterval) -> TimeInterval {
        let floorInterval = 1.0 / Double(max(displayAwareOutputFPSCap(), 1))
        return max(floorInterval, baseInterval / outputFrameThrottlingMode.redrawCadenceCoefficient)
    }

    private func displayAwareOutputFPSCap() -> Int {
        let configuredCap = max(outputFrameThrottlingMode.preferredOutputFPSCap, 1)
        let screenCap = window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 0
        guard screenCap > 0 else { return configuredCap }
        return min(configuredCap, screenCap)
    }

    private func scheduleScrollerSyncIfNeeded() {
        guard pendingScrollSyncState != nil, !scrollerSyncScheduled else { return }
        scrollerSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollerSyncScheduled = false
            guard let state = self.pendingScrollSyncState else { return }
            self.pendingScrollSyncState = nil
            (self.enclosingScrollView as? TerminalScrollView)?.syncScroller(
                scrollbackRowCount: state.scrollbackRowCount,
                viewRows: state.viewRows,
                scrollOffset: state.scrollOffset,
                cellHeight: state.cellHeight
            )
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        ensureDrawableStorageAllocatedIfNeeded()
        super.setNeedsDisplay(invalidRect)
    }

    private func ensurePendingIntentResolutionTimer() {
        guard outputConfirmedInputAnimationsEnabled,
              !pendingCommittedTextIntents.isEmpty,
              pendingIntentResolutionTimer == nil else {
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: committedTextPreviewFrameInterval(), repeats: true) { [weak self] _ in
            guard let self else { return }
            self.resolvePendingCommittedTextIntentsIfNeeded()
            if self.pendingCommittedTextIntents.isEmpty {
                self.pendingIntentResolutionTimer?.invalidate()
                self.pendingIntentResolutionTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingIntentResolutionTimer = timer
    }

    private func updateCursorBlinkTimer() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        guard demandDrivenRendering,
              !renderingSuppressed,
              !isOutputActive,
              window?.isKeyWindow == true,
              let controller = terminalController else {
            return
        }
        let shouldBlink = controller.withModel { $0.cursor.visible && $0.cursor.blinking }
        guard shouldBlink else { return }
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.requestDisplayUpdate()
        }
    }

    private func updateOutputPulseTimer() {
        outputPulseTimer?.invalidate()
        outputPulseTimer = nil
        guard demandDrivenRendering,
              !renderingSuppressed,
              isOutputActive else {
            return
        }
        let interval = scaledOutputPulseInterval(baseInterval: 0.25)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.requestDisplayUpdate()
        }
        RunLoop.main.add(timer, forMode: .common)
        outputPulseTimer = timer
    }

    private func effectiveBorderConfig() -> MetalRenderer.BorderConfig? {
        if isOutputActive {
            let pulse = Float(0.475 + 0.325 * sin(CACurrentMediaTime() * 3.0))
            return MetalRenderer.BorderConfig(
                color: (0.9, 0.2, 0.15, pulse),
                width: 1.5
            )
        }
        return borderConfig
    }

    private func commandIdentityHeaderConfig() -> MetalRenderer.HeaderOverlayConfig? {
        guard commandIdentityHeaderVisible && !suppressCommandIdentityHeaderUntilCommandRelease,
              let controller = terminalController else {
            return nil
        }
        let workspace = controller.sessionSnapshot.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = controller.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = workspace.isEmpty ? title : "\(workspace) - \(title)"
        guard !identity.isEmpty else { return nil }

        let style = WorkspaceIdentityColor.headerStyle(for: workspace.isEmpty ? title : workspace)
        return MetalRenderer.HeaderOverlayConfig(
            text: identity,
            backgroundColor: style.background,
            accentColor: style.accent,
            textColor: style.text,
            usesBoldText: true
        )
    }

    func setCommandModifierActive(_ active: Bool) {
        commandModifierActive = active
    }

    func setCommandIdentityHeaderVisible(_ visible: Bool) {
        commandIdentityHeaderVisible = visible
    }

    func debugSetCommandModifierActive(_ active: Bool) {
        setCommandModifierActive(active)
        setCommandIdentityHeaderVisible(active)
    }

    func debugCommandIdentityHeaderText() -> String? {
        commandIdentityHeaderConfig()?.text
    }

    private func shouldSuppressCommandIdentityHeader(for event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command) &&
        event.modifierFlags.contains(.shift) &&
        event.charactersIgnoringModifiers == "4"
    }

    private func syncSplitContainerCommandIdentityHeaderVisibility() {
        guard renderingSuppressed,
              let splitContainer = enclosingScrollView?.superview as? SplitTerminalContainerView else {
            return
        }
        splitContainer.setIdentityHeaderVisible(commandIdentityHeaderVisible && !suppressCommandIdentityHeaderUntilCommandRelease)
    }

    // MARK: - Grid Position from Mouse

    /// Convert a mouse event location (in view coordinates) to a grid position.
    private func gridPosition(from event: NSEvent) -> GridPosition? {
        guard let renderer = renderer else { return nil }

        let cellW = renderer.glyphAtlas.cellWidth
        let cellH = renderer.glyphAtlas.cellHeight
        guard cellW > 0, cellH > 0 else { return nil }

        let pad = renderer.gridPadding
        let locationInView = convert(event.locationInWindow, from: nil)
        // Flip Y: NSView origin is bottom-left, terminal origin is top-left
        let flippedY = bounds.height - locationInView.y

        let col = max(0, Int((locationInView.x - pad) / cellW))
        let row = max(0, Int((flippedY - pad) / cellH))

        return GridPosition(row: row, col: col)
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        hideImagePreview()
        if shouldSuppressCommandIdentityHeader(for: event) {
            suppressCommandIdentityHeaderUntilCommandRelease = true
        }
        if shortcutConfiguration.matches(.backToIntegrated, event: event) {
            onBackToIntegrated?()
            return
        }
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.control) {
            let handled = ensureKeyboardHandler()?.handleKeyDown(event: event) ?? false
            terminalController?.scrollToBottom()
            clearSelection()
            if handled {
                return
            }
            return
        }

        // Any key press scrolls to bottom and clears selection
        terminalController?.scrollToBottom()
        clearSelection()
        pendingTextInputHandled = false
        if !debugSuppressInterpretKeyEvents {
            interpretKeyEvents([event])
        }
        if !pendingTextInputHandled && !hasMarkedText() {
            if let fallbackText = fallbackDirectTextInput(for: event) {
                enqueueCommittedInsertIntentIfNeeded(for: fallbackText)
            } else {
                enqueueFallbackDeletionIntentIfNeeded(for: event)
            }
            ensureKeyboardHandler()?.handleKeyDown(event: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let commandHeld = event.modifierFlags.contains(.command)
        if !commandHeld {
            suppressCommandIdentityHeaderUntilCommandRelease = false
        }
        commandModifierActive = commandHeld
        if renderingSuppressed,
           let splitContainer = enclosingScrollView?.superview as? SplitTerminalContainerView {
            splitContainer.setCommandModifierActive(commandHeld)
            splitContainer.setIdentityHeaderVisible(commandIdentityHeaderVisible && !suppressCommandIdentityHeaderUntilCommandRelease)
        }
        updateLinkHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if !sendMouseEventIfNeeded(event, phase: .moved) {
            updateImagePreviewHover(with: event)
            updateLinkHover(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hideImagePreview()
        if hoveredLinkRange != nil {
            hoveredLinkRange = nil
            NSCursor.arrow.set()
        }
    }

    private func updateImagePreviewHover(with event: NSEvent) {
        guard let controller = terminalController,
              let position = gridPosition(from: event),
              let placeholder = controller.detectedImagePlaceholder(at: position),
              let ownerID = placeholder.ownerID,
              let imageURL = imagePreviewURLProvider?(ownerID, placeholder.index) else {
            hoveredImagePlaceholder = nil
            hideImagePreview()
            return
        }

        let hoverChanged = hoveredImagePlaceholder != placeholder
        hoveredImagePlaceholder = placeholder
        if hoverChanged || imagePreviewWindow == nil {
            guard let image = NSImage(contentsOf: imageURL) else {
                hideImagePreview()
                return
            }
            showImagePreview(image, for: event)
        } else {
            positionImagePreview(near: event)
        }
    }

    private func updateLinkHover(with event: NSEvent) {
        let commandHeld = event.modifierFlags.contains(.command)
        guard commandHeld,
              let controller = terminalController,
              let position = gridPosition(from: event),
              let link = controller.detectedLink(at: position) else {
            if hoveredLinkRange != nil {
                hoveredLinkRange = nil
                NSCursor.arrow.set()
            }
            return
        }

        let newRange = (row: position.row, startCol: link.startCol, endCol: link.endCol)
        if hoveredLinkRange?.row != newRange.row ||
           hoveredLinkRange?.startCol != newRange.startCol ||
           hoveredLinkRange?.endCol != newRange.endCol {
            hoveredLinkRange = newRange
            NSCursor.pointingHand.set()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let controller = terminalController,
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
              ) as? [URL],
              !urls.isEmpty else {
            return false
        }

        let quotedPaths = urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        controller.sendInput(quotedPaths.joined(separator: " "))
        return true
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        hideImagePreview()

        if event.modifierFlags.contains(.command) {
            if handleDetectedLinkClick(event) {
                return
            }
            if event.modifierFlags.contains(.shift),
               let onShiftCommandClick {
                onShiftCommandClick()
                return
            }
            window?.makeFirstResponder(self)
            if let onCmdClick {
                onCmdClick()
                return
            }
        }

        window?.makeFirstResponder(self)

        if sendMouseEventIfNeeded(event, phase: .down, buttonOverride: 0) {
            return
        }

        guard let pos = gridPosition(from: event) else { return }

        let now = event.timestamp

        // Detect multi-click (double/triple)
        if let lastPos = lastClickPosition,
           lastPos == pos,
           now - lastClickTime < Self.multiClickInterval {
            clickCount += 1
        } else {
            clickCount = 1
        }
        lastClickTime = now
        lastClickPosition = pos

        if clickCount == 2 {
            // Double-click: word selection
            guard let controller = terminalController else { return }
            controller.withModel { model in
                selection = TerminalSelection.wordSelection(at: pos, in: model.grid)
            }
            return
        }

        if clickCount >= 3 {
            // Triple-click: line selection
            guard let controller = terminalController else { return }
            controller.withModel { model in
                selection = TerminalSelection.lineSelection(row: pos.row, cols: model.cols)
            }
            clickCount = 3 // cap
            return
        }

        // Single click
        if event.modifierFlags.contains(.shift), var sel = selection {
            // Shift+click: extend selection
            sel.active = pos
            selection = sel
        } else {
            // Start new selection
            let mode: SelectionMode = event.modifierFlags.contains(.option) ? .rectangular : .normal
            var newSelection = TerminalSelection(anchor: pos, active: pos, mode: mode)
            newSelection.isDragging = true
            selection = newSelection
        }
    }

    private func handleDetectedLinkClick(_ event: NSEvent) -> Bool {
        guard let controller = terminalController,
              let position = gridPosition(from: event),
              let detectedLink = controller.detectedLink(at: position) else {
            return false
        }

        hoveredLinkRange = nil
        NSCursor.arrow.set()

        let scheme = detectedLink.url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(detectedLink.url)
            return true
        }

        let alert = NSAlert.pterm()
        alert.messageText = "Open this URL?"
        alert.informativeText = detectedLink.originalText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return true
        }

        NSWorkspace.shared.open(detectedLink.url)
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        hideImagePreview()
        window?.makeFirstResponder(self)
        if !sendMouseEventIfNeeded(event, phase: .down, buttonOverride: 2) {
            super.rightMouseDown(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        hideImagePreview()
        window?.makeFirstResponder(self)
        if !sendMouseEventIfNeeded(event, phase: .down, buttonOverride: 1) {
            super.otherMouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if sendMouseEventIfNeeded(event, phase: .dragged) {
            return
        }
        guard var sel = selection, sel.isDragging else { return }
        autoScrollSelectionIfNeeded(for: event)
        guard let pos = clampedGridPosition(from: event) else { return }

        sel.active = pos
        selection = sel
    }

    override func rightMouseDragged(with event: NSEvent) {
        if !sendMouseEventIfNeeded(event, phase: .dragged) {
            super.rightMouseDragged(with: event)
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if !sendMouseEventIfNeeded(event, phase: .dragged) {
            super.otherMouseDragged(with: event)
        }
    }

    private func autoScrollSelectionIfNeeded(for event: NSEvent) {
        guard let controller = terminalController,
              let renderer = renderer else { return }

        let location = convert(event.locationInWindow, from: nil)
        let margin = renderer.glyphAtlas.cellHeight
        guard margin > 0 else { return }

        if location.y < 0 {
            let lines = max(1, Int(ceil(abs(location.y) / margin)))
            if controller.scrollDown(lines: lines) {
                (enclosingScrollView as? TerminalScrollView)?.syncScroller()
            }
        } else if location.y > bounds.height {
            let lines = max(1, Int(ceil((location.y - bounds.height) / margin)))
            if controller.scrollUp(lines: lines) {
                (enclosingScrollView as? TerminalScrollView)?.syncScroller()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedMouseButton = nil }
        if sendMouseEventIfNeeded(event, phase: .up) {
            return
        }
        guard var sel = selection else { return }

        if sel.isDragging {
            if let pos = gridPosition(from: event) {
                sel.active = pos
            }
            sel.isDragging = false

            // If the selection is empty (click without drag), clear it
            if sel.isEmpty {
                selection = nil
            } else {
                selection = sel
            }
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        defer { pressedMouseButton = nil }
        if !sendMouseEventIfNeeded(event, phase: .up) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        defer { pressedMouseButton = nil }
        if !sendMouseEventIfNeeded(event, phase: .up) {
            super.otherMouseUp(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        hideImagePreview()
        if sendMouseEventIfNeeded(event, phase: .scroll) {
            return
        }
        // When inside a TerminalScrollView, forward to NSScrollView
        // so it handles scrolling natively (shows overlay scroller, momentum, etc.).
        // The scrollViewDidScroll notification translates clip position → scrollOffset.
        if enclosingScrollView is TerminalScrollView {
            super.scrollWheel(with: event)
            return
        }

        // Direct handling when not inside a scroll view (standalone mode)
        guard let controller = terminalController,
              let renderer = renderer else { return }

        let cellH = renderer.glyphAtlas.cellHeight
        guard cellH > 0 else { return }

        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += event.scrollingDeltaY

            let lines = Int(scrollAccumulator / cellH)
            if lines != 0 {
                scrollAccumulator -= CGFloat(lines) * cellH
                if lines > 0 {
                    controller.scrollUp(lines: lines)
                } else {
                    controller.scrollDown(lines: -lines)
                }
            }
        } else {
            let lines = 3
            if event.scrollingDeltaY > 0 {
                controller.scrollUp(lines: lines)
            } else if event.scrollingDeltaY < 0 {
                controller.scrollDown(lines: lines)
            }
        }
    }

    private enum MousePhase {
        case down
        case up
        case dragged
        case moved
        case scroll
    }

    private func sendMouseEventIfNeeded(_ event: NSEvent,
                                        phase: MousePhase,
                                        buttonOverride: Int? = nil) -> Bool {
        guard !event.modifierFlags.contains(.option),
              let controller = terminalController,
              let position = clampedGridPosition(from: event),
              let state = controller.withModel({ model -> MouseReportingState? in
                  guard model.mouseReporting != .none else { return nil }
                  return MouseReportingState(mode: model.mouseReporting, protocolMode: model.mouseProtocol)
              }) else {
            return false
        }

        switch phase {
        case .down:
            pressedMouseButton = buttonOverride ?? mouseButtonCode(for: event)
            guard let button = pressedMouseButton else { return false }
            controller.sendInput(encodeMouse(button: button, position: position, phase: .down,
                                             protocolMode: state.protocolMode))
            return true
        case .up:
            guard state.mode != .x10 else { return true }
            controller.sendInput(encodeMouse(button: pressedMouseButton ?? mouseButtonCode(for: event) ?? 0,
                                             position: position, phase: .up,
                                             protocolMode: state.protocolMode))
            return true
        case .dragged:
            guard state.mode == .buttonEvent || state.mode == .anyEvent,
                  let button = pressedMouseButton ?? mouseButtonCode(for: event) else { return false }
            controller.sendInput(encodeMouse(button: button, position: position, phase: .dragged,
                                             protocolMode: state.protocolMode))
            return true
        case .moved:
            guard state.mode == .anyEvent else { return false }
            controller.sendInput(encodeMouse(button: pressedMouseButton ?? 0, position: position, phase: .moved,
                                             protocolMode: state.protocolMode))
            return true
        case .scroll:
            guard event.scrollingDeltaY != 0 else { return false }
            let button = event.scrollingDeltaY > 0 ? 64 : 65
            controller.sendInput(encodeMouse(button: button, position: position, phase: .scroll,
                                             protocolMode: state.protocolMode))
            return true
        }
    }

    private func clampedGridPosition(from event: NSEvent) -> GridPosition? {
        guard let controller = terminalController,
              let position = gridPosition(from: event) else { return nil }
        let size = controller.withModel { ($0.rows, $0.cols) }
        return GridPosition(
            row: min(max(position.row, 0), max(0, size.0 - 1)),
            col: min(max(position.col, 0), max(0, size.1 - 1))
        )
    }

    private func mouseButtonCode(for event: NSEvent) -> Int? {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return 0
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
            return 2
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            return 1
        default:
            return 0
        }
    }

    private func encodeMouse(button: Int,
                             position: GridPosition,
                             phase: MousePhase,
                             protocolMode: TerminalModel.MouseProtocol) -> String {
        let col = position.col + 1
        let row = position.row + 1
        let baseCode: Int
        switch phase {
        case .up:
            baseCode = 3
        case .dragged, .moved:
            baseCode = button | 32
        case .down, .scroll:
            baseCode = button
        }

        switch protocolMode {
        case .sgr:
            let suffix = phase == .up ? "m" : "M"
            return "\u{1B}[<\(baseCode);\(col);\(row)\(suffix)"
        case .utf8:
            let bytes: [UInt8] = [
                0x1B, 0x5B, 0x4D,
                UInt8(min(255, 32 + baseCode))
            ] + utf8MouseCoordinateBytes(33 + col) + utf8MouseCoordinateBytes(33 + row)
            return String(decoding: bytes, as: UTF8.self)
        case .x10:
            let bytes: [UInt8] = [
                0x1B, 0x5B, 0x4D,
                UInt8(min(255, 32 + baseCode)),
                UInt8(min(255, 33 + col)),
                UInt8(min(255, 33 + row))
            ]
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private func utf8MouseCoordinateBytes(_ value: Int) -> [UInt8] {
        let clamped = max(0, min(value, 0x10FFFF))
        return Array(String(UnicodeScalar(clamped)!).utf8)
    }

    // MARK: - Selection API

    /// Clear the current selection.
    func clearSelection() {
        selectAllActive = false
        selection = nil
    }

    func beginSearch() {
        if selectionBeforeSearch == nil {
            selectionBeforeSearch = selection
        }
    }

    func updateSearch(query: String) -> (current: Int?, total: Int) {
        guard let controller = terminalController else {
            searchMatches = []
            currentSearchIndex = nil
            selection = nil
            return (nil, 0)
        }
        if query.isEmpty {
            searchMatches = []
            currentSearchIndex = nil
            selection = selectionBeforeSearch
            return (nil, 0)
        }

        searchMatches = controller.findMatches(for: query)
        if searchMatches.isEmpty {
            currentSearchIndex = nil
            selection = nil
            return (nil, 0)
        }

        currentSearchIndex = 0
        selection = controller.revealSearchMatch(searchMatches[0])
        return (1, searchMatches.count)
    }

    func navigateSearch(forward: Bool) -> (current: Int?, total: Int) {
        guard let controller = terminalController, !searchMatches.isEmpty else {
            return (nil, 0)
        }
        let nextIndex: Int
        if let currentSearchIndex {
            let delta = forward ? 1 : -1
            nextIndex = (currentSearchIndex + delta + searchMatches.count) % searchMatches.count
        } else {
            nextIndex = 0
        }
        currentSearchIndex = nextIndex
        selection = controller.revealSearchMatch(searchMatches[nextIndex])
        return (nextIndex + 1, searchMatches.count)
    }

    func endSearch() {
        searchMatches = []
        currentSearchIndex = nil
        selection = selectionBeforeSearch
        selectionBeforeSearch = nil
    }

    /// Select all text in the terminal.
    func selectAll() {
        guard let controller = terminalController else { return }
        selectAllActive = true
        controller.withModel { model in
            selection = TerminalSelection(
                anchor: GridPosition(row: 0, col: 0),
                active: GridPosition(row: model.rows - 1, col: model.cols - 1),
                mode: .normal
            )
        }
    }

    /// Get the selected text, or nil if no selection.
    func selectedText() -> String? {
        guard let controller = terminalController else { return nil }
        if selectAllActive {
            return controller.allText()
        }
        guard let sel = selection, !sel.isEmpty else { return nil }
        return controller.selectedText(for: sel)
    }

    func cutMarkedText() -> String? {
        guard let text = markedTextStorage?.string, !text.isEmpty else { return nil }
        unmarkText()
        pendingTextInputHandled = true
        return text
    }

    @discardableResult
    func undoMarkedText() -> Bool {
        guard hasMarkedText() else { return false }
        unmarkText()
        pendingTextInputHandled = true
        return true
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        hideImagePreview()
        _ = syncDrawableSizeToBoundsIfNeeded()
        updateTerminalSize(notificationMode: .immediateOnly)
        updateMarkedTextOverlay()
        requestDisplayUpdate()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        hideImagePreview()
        _ = syncDrawableSizeToBoundsIfNeeded()
        updateTerminalSize(notificationMode: .immediateOnly)
        updateMarkedTextOverlay()
        requestDisplayUpdate()
    }

    @discardableResult
    private func updateTerminalSize() -> Bool {
        guard let renderer = renderer,
              let controller = terminalController else { return false }

        let cellW = renderer.glyphAtlas.cellWidth
        let cellH = renderer.glyphAtlas.cellHeight

        guard cellW > 0, cellH > 0 else { return false }

        let pad = renderer.gridPadding * 2  // padding on both sides
        let cols = max(1, Int((bounds.width - pad) / cellW))
        let rows = max(1, Int((bounds.height - pad) / cellH))

        let currentSize = controller.withModel { model in
            (rows: model.rows, cols: model.cols)
        }
        guard currentSize.rows != rows || currentSize.cols != cols else {
            return false
        }

        controller.resize(rows: rows, cols: cols)

        // Clear selection on resize (grid coordinates change)
        clearSelection()
        return true
    }

    @discardableResult
    private func updateTerminalSize(notificationMode: ResizeNotificationMode) -> Bool {
        let changed = updateTerminalSize()
        guard changed else { return false }
        switch notificationMode {
        case .immediateOnly:
            cancelDeferredResizeNotifications()
        case .immediateAndDeferred:
            scheduleDeferredResizeNotification()
        }
        return true
    }

    private func cancelDeferredResizeNotifications() {
        deferredResizeNotificationWorkItems.forEach { $0.cancel() }
        deferredResizeNotificationWorkItems.removeAll()
    }

    private func scheduleDeferredResizeNotification() {
        cancelDeferredResizeNotifications()
        guard let controller = terminalController else { return }
        let delays: [TimeInterval] = [0.05, 0.20]
        deferredResizeNotificationWorkItems = delays.map { delay in
            let workItem = DispatchWorkItem { [weak self, weak controller] in
                guard let self, let controller, !self.renderingSuppressed else { return }
                controller.notifyCurrentSizeChanged()
                self.requestDisplayUpdate()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return workItem
        }
    }

    /// Called when font size changes. Recalculates terminal grid dimensions.
    func fontSizeDidChange() {
        updateTerminalSize(notificationMode: .immediateAndDeferred)
        updateMarkedTextOverlay()
    }

    /// Update only the IME overlay without triggering a terminal resize.
    func updateMarkedTextOverlayPublic() {
        updateMarkedTextOverlay()
    }

    /// Force a resize pass using the current viewport immediately.
    /// Split/focused transitions can change width before the next output arrives,
    /// and we want the PTY rows/cols to match right away.
    func refreshTerminalLayoutForCurrentBounds() {
        _ = syncDrawableSizeToBoundsIfNeeded()
        updateTerminalSize(notificationMode: .immediateOnly)
        updateMarkedTextOverlay()
        requestDisplayUpdate()
    }

    static func clampedImagePreviewSize(
        for imageSize: NSSize,
        maxSize: NSSize = NSSize(width: 640, height: 480)
    ) -> NSSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let widthScale = maxSize.width / imageSize.width
        let heightScale = maxSize.height / imageSize.height
        let scale = min(1.0, widthScale, heightScale)
        return NSSize(width: floor(imageSize.width * scale), height: floor(imageSize.height * scale))
    }

    private func showImagePreview(_ image: NSImage, for event: NSEvent) {
        let clampedSize = Self.clampedImagePreviewSize(for: image.size)
        guard clampedSize.width > 0, clampedSize.height > 0 else {
            hideImagePreview()
            return
        }

        let previewWindow: NSWindow
        let previewView: NSImageView
        if let existingWindow = imagePreviewWindow, let existingView = imagePreviewView {
            previewWindow = existingWindow
            previewView = existingView
        } else {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: NSSize(width: clampedSize.width + 16, height: clampedSize.height + 16)),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .statusBar
            window.hasShadow = true
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace]

            let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: window.frame.size))
            root.material = .hudWindow
            root.blendingMode = .withinWindow
            root.state = .active
            root.wantsLayer = true
            root.layer?.cornerRadius = 10
            root.layer?.masksToBounds = true

            let imageView = NSImageView(frame: root.bounds.insetBy(dx: 8, dy: 8))
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            root.addSubview(imageView)
            window.contentView = root

            imagePreviewWindow = window
            imagePreviewView = imageView
            previewWindow = window
            previewView = imageView
        }

        previewView.image = image
        previewWindow.setContentSize(NSSize(width: clampedSize.width + 16, height: clampedSize.height + 16))
        if let root = previewWindow.contentView {
            root.frame = NSRect(origin: .zero, size: previewWindow.frame.size)
            previewView.frame = root.bounds.insetBy(dx: 8, dy: 8)
        }
        positionImagePreview(near: event)
        previewWindow.orderFront(nil)
    }

    private func positionImagePreview(near event: NSEvent) {
        guard let previewWindow = imagePreviewWindow,
              let hostWindow = window else { return }

        let pointInView = convert(event.locationInWindow, from: nil)
        var screenPoint = hostWindow.convertToScreen(NSRect(
            x: pointInView.x + 16,
            y: pointInView.y - 16,
            width: 0,
            height: 0
        )).origin
        let previewSize = previewWindow.frame.size

        if let visibleFrame = hostWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            if screenPoint.x + previewSize.width > visibleFrame.maxX {
                screenPoint.x = max(visibleFrame.minX, visibleFrame.maxX - previewSize.width - 12)
            }
            if screenPoint.y - previewSize.height < visibleFrame.minY {
                screenPoint.y = min(visibleFrame.maxY - previewSize.height, screenPoint.y + 32)
            } else {
                screenPoint.y -= previewSize.height
            }
        }

        previewWindow.setFrameOrigin(screenPoint)
    }

    private func hideImagePreview() {
        hoveredImagePlaceholder = nil
        imagePreviewWindow?.orderOut(nil)
        imagePreviewView = nil
        imagePreviewWindow = nil
    }

    private func currentCursorRect() -> NSRect {
        guard let controller = terminalController,
              let renderer = renderer else {
            return .zero
        }
        let cursor = controller.withModel { $0.cursor }
        return NSRect(
            x: renderer.gridPadding + CGFloat(cursor.col) * renderer.glyphAtlas.cellWidth,
            y: bounds.height - renderer.gridPadding - CGFloat(cursor.row + 1) * renderer.glyphAtlas.cellHeight,
            width: renderer.glyphAtlas.cellWidth,
            height: renderer.glyphAtlas.cellHeight
        )
    }

    private func updateMarkedTextOverlay() {
        guard let visibleMarkedTextStorage = visibleMarkedTextStorage(),
              let renderer = renderer else {
            destroyMarkedTextLayer()
            return
        }
        configureMarkedTextLayer()
        guard let markedTextLayer else { return }

        let font = NSFont(name: renderer.glyphAtlas.fontName, size: renderer.glyphAtlas.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: renderer.glyphAtlas.fontSize, weight: .regular)
        let cursorRect = currentCursorRect()
        markedTextLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        markedTextLayer.string = nil
        markedTextLayer.frame = bounds
        rebuildMarkedTextGlyphLayers(
            for: visibleMarkedTextStorage.string,
            font: font,
            cursorRect: cursorRect,
            contentsScale: markedTextLayer.contentsScale
        )
        markedTextLayer.isHidden = true
    }

    private func rebuildMarkedTextGlyphLayers(
        for text: String,
        font: NSFont,
        cursorRect: CGRect,
        contentsScale: CGFloat
    ) {
        guard let renderer else { return }

        markedTextGlyphFrames.removeAll(keepingCapacity: false)

        let scale = renderer.glyphAtlas.scaleFactor
        let baseY = cursorRect.minY
        let textHeight = max(font.boundingRectForFont.height, cursorRect.height)
        var columnOffsetPoints: CGFloat = 0

        for character in text {
            let grapheme = String(character)
            let columnWidth = max(self.columnWidth(for: grapheme), 1)
            defer { columnOffsetPoints += CGFloat(columnWidth) * renderer.glyphAtlas.cellWidth }

            guard let firstScalar = grapheme.unicodeScalars.first,
                  firstScalar.value > 0x20,
                  let glyph = renderer.glyphAtlas.glyphInfo(for: firstScalar.value),
                  glyph.pixelWidth > 0 else {
                continue
            }

            let glyphX: CGFloat
            if columnWidth == 1 {
                glyphX = cursorRect.minX + columnOffsetPoints + (CGFloat(glyph.cellOffsetX) / scale)
            } else {
                let spanWidth = CGFloat(columnWidth) * renderer.glyphAtlas.cellWidth
                glyphX = cursorRect.minX +
                    columnOffsetPoints +
                    (CGFloat(glyph.cellOffsetX) / scale) +
                    ((spanWidth - renderer.glyphAtlas.cellWidth) * 0.5)
            }

            let glyphFrame = NSRect(
                x: glyphX,
                y: baseY,
                width: max(CGFloat(glyph.pixelWidth) / scale, 1),
                height: textHeight
            )
            markedTextGlyphFrames.append(glyphFrame)
        }
    }

    private func shouldAnimateCommittedTextPreview(for text: String) -> Bool {
        guard !text.isEmpty,
              !hasMarkedText(),
              !text.contains("\n"),
              !text.contains("\r") else {
            return false
        }
        return text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func previewAlpha(for committedTextPreview: CommittedTextPreview, progress: Double) -> Float {
        let easedProgress = progress * progress * (3.0 - 2.0 * progress)
        switch committedTextPreview.kind {
        case .fadeIn:
            let delayedProgress = pow(progress, 2.1)
            let smoothedProgress = delayedProgress * delayedProgress * (3.0 - 2.0 * delayedProgress)
            return Float(0.02 + 0.98 * smoothedProgress)
        case .fadeOut:
            return Float(0.4 * (1.0 - easedProgress))
        case .hold:
            return 1.0
        }
    }

    private func overlay(for committedTextPreview: CommittedTextPreview, at now: CFTimeInterval) -> MetalRenderer.TransientTextOverlay? {
        let elapsed = now - committedTextPreview.startedAt
        guard elapsed < committedTextPreview.duration else { return nil }
        let progress = max(0.0, min(1.0, elapsed / committedTextPreview.duration))
        let alpha = previewAlpha(for: committedTextPreview, progress: progress)
        return MetalRenderer.TransientTextOverlay(
            text: committedTextPreview.text,
            row: committedTextPreview.row,
            col: committedTextPreview.col,
            columnWidth: committedTextPreview.columnWidth,
            cursorRow: committedTextPreview.cursorRow,
            cursorCol: committedTextPreview.cursorCol,
            masksGridGlyphs: committedTextPreview.kind == .fadeIn || committedTextPreview.kind == .hold,
            verticalOffset: committedTextPreview.kind == .fadeOut ? Float(20.0 * easedFall(progress)) : 0,
            alpha: alpha
        )
    }

    func activeCommittedTextPreviewOverlays() -> [MetalRenderer.TransientTextOverlay] {
        guard !committedTextPreviews.isEmpty else { return [] }
        let now = CACurrentMediaTime()
        committedTextPreviews = committedTextPreviews.filter { now - $0.startedAt < $0.duration }
        if committedTextPreviews.isEmpty {
            committedTextPreviewTimer?.invalidate()
            committedTextPreviewTimer = nil
            return []
        }
        return committedTextPreviews.compactMap { overlay(for: $0, at: now) }
    }

    private func easedFall(_ progress: Double) -> Double {
        progress * progress * (3.0 - 2.0 * progress)
    }

    private func activeMarkedTextTransientOverlays() -> [MetalRenderer.TransientTextOverlay] {
        let now = CACurrentMediaTime()
        guard let controller = terminalController,
              let visibleMarkedTextStorage = visibleMarkedTextStorage() else {
            return []
        }

        if let segment = markedTextAnimatedSegment,
           now - segment.startedAt >= 0.20 {
            markedTextAnimatedSegment = nil
        }

        let cursor = controller.withModel { $0.cursor }
        let visibleString = visibleMarkedTextStorage.string
        let visibleSelection = visibleMarkedTextSelection()
        let nsString = visibleString as NSString
        let selectionLocation = visibleSelection.location == NSNotFound
            ? nsString.length
            : min(max(0, visibleSelection.location), nsString.length)
        let prefix = nsString.substring(to: selectionLocation)
        let cursorCol = cursor.col + (prefix.isEmpty ? 0 : columnWidth(for: prefix))
        let markedTextAlpha: Float = 0.4

        guard let segment = markedTextAnimatedSegment,
              !segment.text.isEmpty else {
            return [
                MetalRenderer.TransientTextOverlay(
                    text: visibleString,
                    row: cursor.row,
                    col: cursor.col,
                    columnWidth: columnWidth(for: visibleString),
                    cursorRow: cursor.row,
                    cursorCol: cursorCol,
                    masksGridGlyphs: true,
                    verticalOffset: 0,
                    alpha: markedTextAlpha,
                    underline: true
                )
            ]
        }

        let characters = Array(visibleString)
        let prefixCharacters = characters.prefix(segment.colOffset)
        let animatedCharacters = Array(segment.text)
        let suffixCharacters = characters.dropFirst(segment.colOffset + animatedCharacters.count)
        let stablePrefix = String(prefixCharacters)
        let stableSuffix = String(suffixCharacters)
        let animatedCol = cursor.col + (stablePrefix.isEmpty ? 0 : columnWidth(for: stablePrefix))
        let suffixCol = animatedCol + columnWidth(for: segment.text)

        var overlays: [MetalRenderer.TransientTextOverlay] = []
        if !stablePrefix.isEmpty {
            overlays.append(
                MetalRenderer.TransientTextOverlay(
                    text: stablePrefix,
                    row: cursor.row,
                    col: cursor.col,
                    columnWidth: columnWidth(for: stablePrefix),
                    cursorRow: nil,
                    cursorCol: nil,
                    masksGridGlyphs: true,
                    verticalOffset: 0,
                    alpha: markedTextAlpha,
                    underline: true
                )
            )
        }

        let animatedPreview = CommittedTextPreview(
            text: segment.text,
            row: cursor.row,
            col: animatedCol,
            columnWidth: columnWidth(for: segment.text),
            cursorRow: cursor.row,
            cursorCol: cursorCol,
            startedAt: segment.startedAt,
            duration: 0.20,
            kind: .fadeIn
        )
        if var animatedOverlay = overlay(for: animatedPreview, at: now) {
            animatedOverlay.alpha = min(animatedOverlay.alpha, markedTextAlpha)
            animatedOverlay.underline = true
            overlays.append(animatedOverlay)
        }

        if !stableSuffix.isEmpty {
            overlays.append(
                MetalRenderer.TransientTextOverlay(
                    text: stableSuffix,
                    row: cursor.row,
                    col: suffixCol,
                    columnWidth: columnWidth(for: stableSuffix),
                    cursorRow: nil,
                    cursorCol: nil,
                    masksGridGlyphs: true,
                    verticalOffset: 0,
                    alpha: markedTextAlpha,
                    underline: true
                )
            )
        }
        return overlays
    }

    func activeTransientTextOverlaysForRendering() -> [MetalRenderer.TransientTextOverlay] {
        activeCommittedTextPreviewOverlays() + activeMarkedTextTransientOverlays()
    }

    private func columnWidth(for text: String) -> Int {
        max(1, text.unicodeScalars.reduce(0) { partial, scalar in
            max(partial + max(CharacterWidth.width(of: scalar.value), 0), 1)
        })
    }

    private func animatedMarkedTextSegment(
        previous previousText: String?,
        current currentText: String
    ) -> (text: String, colOffset: Int)? {
        let currentCharacters = Array(currentText)
        guard !currentCharacters.isEmpty else { return nil }
        guard let previousText, !previousText.isEmpty else {
            let lastIndex = max(currentCharacters.count - 1, 0)
            return (String(currentCharacters[lastIndex]), lastIndex)
        }

        let previousCharacters = Array(previousText)
        var prefixCount = 0
        let prefixLimit = min(previousCharacters.count, currentCharacters.count)
        while prefixCount < prefixLimit && previousCharacters[prefixCount] == currentCharacters[prefixCount] {
            prefixCount += 1
        }

        if prefixCount == currentCharacters.count {
            return nil
        }
        let lastIndex = currentCharacters.count - 1
        let segmentStart = max(prefixCount, lastIndex)
        return (String(currentCharacters[lastIndex]), segmentStart)
    }

    /// Create fade-out animations for characters removed or replaced during IME
    /// composition, so that the visual behavior matches non-IME deletion.
    private func showMarkedTextDeletionPreviews(previous previousText: String?, current currentText: String) {
        guard let previousText, !previousText.isEmpty,
              let controller = terminalController else { return }
        let previousCharacters = Array(previousText)
        let currentCharacters = Array(currentText)

        // Find the common prefix that is unchanged.
        var prefixCount = 0
        let prefixLimit = min(previousCharacters.count, currentCharacters.count)
        while prefixCount < prefixLimit && previousCharacters[prefixCount] == currentCharacters[prefixCount] {
            prefixCount += 1
        }

        // Nothing was removed or replaced.
        guard prefixCount < previousCharacters.count else { return }

        let cursor = controller.withModel { $0.cursor }

        // Compute the column offset of the first changed character.
        var colOffset = 0
        for i in 0..<prefixCount {
            colOffset += columnWidth(for: String(previousCharacters[i]))
        }

        // Fade out every previous character beyond the common prefix.
        // No shouldAnimateCommittedTextPreview check: these characters
        // were already visible as marked text, so we know they're printable.
        for i in prefixCount..<previousCharacters.count {
            let charText = String(previousCharacters[i])
            let charWidth = columnWidth(for: charText)
            showCommittedTextPreview(
                text: charText,
                row: cursor.row,
                col: cursor.col + colOffset,
                columnWidth: charWidth,
                cursorRow: nil,
                cursorCol: nil,
                kind: .fadeOut,
                duration: 0.34
            )
            colOffset += charWidth
        }
    }

    private func showCommittedTextPreview(
        text: String,
        row: Int,
        col: Int,
        columnWidth: Int,
        cursorRow: Int?,
        cursorCol: Int?,
        kind: CommittedTextPreview.Kind,
        duration: CFTimeInterval
    ) {
        committedTextPreviews.append(CommittedTextPreview(
            text: text,
            row: row,
            col: col,
            columnWidth: columnWidth,
            cursorRow: cursorRow,
            cursorCol: cursorCol,
            startedAt: CACurrentMediaTime(),
            duration: duration,
            kind: kind
        ))
        if kind == .fadeIn && !outputConfirmedInputAnimationsEnabled {
            recordRecentCommittedInsertion(text: text, row: row, col: col, columnWidth: columnWidth)
        } else {
            discardRecentCommittedInsertion(text: text, row: row, col: col, columnWidth: columnWidth)
        }
        if committedTextPreviews.count > PreviewPolicy.maxCommittedTextPreviewCount {
            committedTextPreviews.removeFirst(committedTextPreviews.count - PreviewPolicy.maxCommittedTextPreviewCount)
        }
        ensureTransientOverlayAnimationTimer()
        requestDisplayUpdate()
    }

    private func hasActiveMarkedTextAnimations(at now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard hasMarkedText(), let startedAt = markedTextPreviewStartedAt else {
            return false
        }
        return now - startedAt < 0.20 || markedTextAnimatedSegment != nil
    }

    private func ensureTransientOverlayAnimationTimer() {
        committedTextPreviewTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: committedTextPreviewFrameInterval(), repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.activeCommittedTextPreviewOverlays().isEmpty && !self.hasActiveMarkedTextAnimations() {
                self.committedTextPreviewTimer?.invalidate()
                self.committedTextPreviewTimer = nil
                return
            }
            self.requestDisplayUpdate()
        }
        RunLoop.main.add(timer, forMode: .common)
        committedTextPreviewTimer = timer
    }

    private func recordRecentCommittedInsertion(text: String, row: Int, col: Int, columnWidth: Int) {
        recentCommittedInsertions.append(contentsOf: recentCommittedInsertionSegments(text: text, row: row, col: col))
        if recentCommittedInsertions.count > PreviewPolicy.maxCommittedTextPreviewCount {
            recentCommittedInsertions.removeFirst(recentCommittedInsertions.count - PreviewPolicy.maxCommittedTextPreviewCount)
        }
    }

    private func discardRecentCommittedInsertion(text: String, row: Int, col: Int, columnWidth: Int) {
        let segments = recentCommittedInsertionSegments(text: text, row: row, col: col)
        for segment in segments.reversed() {
            if let index = recentCommittedInsertions.lastIndex(where: {
                $0.text == segment.text &&
                $0.row == segment.row &&
                $0.col == segment.col &&
                $0.columnWidth == segment.columnWidth
            }) {
                recentCommittedInsertions.remove(at: index)
            }
        }
    }

    private func recentCommittedInsertionSegments(text: String, row: Int, col: Int) -> [RecentCommittedInsertion] {
        var segments: [RecentCommittedInsertion] = []
        segments.reserveCapacity(text.count)
        var currentCol = col
        for character in text {
            let segmentText = String(character)
            let segmentWidth = columnWidth(for: segmentText)
            segments.append(
                RecentCommittedInsertion(
                    text: segmentText,
                    row: row,
                    col: currentCol,
                    columnWidth: segmentWidth
                )
            )
            currentCol += segmentWidth
        }
        return segments
    }

    private func showCommittedTextPreview(_ text: String) {
        guard shouldAnimateCommittedTextPreview(for: text),
              let controller = terminalController else { return }
        let cursor = controller.withModel { $0.cursor }
        showCommittedTextPreview(
            text: text,
            row: cursor.row,
            col: cursor.col,
            columnWidth: columnWidth(for: text),
            cursorRow: cursor.row,
            cursorCol: cursor.col + columnWidth(for: text),
            kind: .fadeIn,
            duration: 0.20
        )
    }

    private func enqueueCommittedInsertIntentIfNeeded(for text: String) {
        guard outputConfirmedInputAnimationsEnabled,
              shouldAnimateCommittedTextPreview(for: text),
              let controller = terminalController else {
            return
        }
        let cursor = controller.withModel { $0.cursor }
        let width = columnWidth(for: text)
        recordRecentCommittedInsertion(text: text, row: cursor.row, col: cursor.col, columnWidth: width)
        enqueueCommittedTextIntent(
            kind: .insert,
            text: text,
            row: cursor.row,
            col: cursor.col,
            columnWidth: width,
            cursorRow: cursor.row,
            cursorCol: cursor.col + width
        )
    }

    private func fallbackDirectTextInput(for event: NSEvent) -> String? {
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !hasMarkedText(),
              ensureKeyboardHandler()?.debugWillTreatAsRegularTextInput(event: event) == true,
              let characters = event.characters,
              shouldAnimateCommittedTextPreview(for: characters) else {
            return nil
        }
        return characters
    }

    private func enqueueFallbackDeletionIntentIfNeeded(for event: NSEvent) {
        guard outputConfirmedInputAnimationsEnabled,
              !hasMarkedText(),
              let selector = ensureKeyboardHandler()?.debugSpecialKeySelector(for: event) else {
            return
        }
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)):
            if let preview = deletionPreview(backward: true),
               shouldAnimateCommittedTextPreview(for: preview.text) {
                enqueueCommittedTextIntent(
                    kind: .deleteBackward,
                    text: preview.text,
                    row: preview.row,
                    col: preview.col,
                    columnWidth: preview.width,
                    cursorRow: preview.row,
                    cursorCol: preview.col
                )
            }
        case #selector(NSResponder.deleteForward(_:)):
            if let preview = deletionPreview(backward: false),
               shouldAnimateCommittedTextPreview(for: preview.text) {
                enqueueCommittedTextIntent(
                    kind: .deleteForward,
                    text: preview.text,
                    row: preview.row,
                    col: preview.col,
                    columnWidth: preview.width,
                    cursorRow: preview.row,
                    cursorCol: preview.col
                )
            }
        default:
            break
        }
    }

    private func currentViewportSnapshot() -> TerminalViewportTextSnapshot? {
        guard let controller = terminalController else { return nil }
        return controller.withViewport { model, scrollback, scrollOffset in
            let rows = model.rows
            let cols = model.cols
            let scrollbackRowCount = scrollback.rowCount
            let firstAbsolute = scrollOffset > 0 ? max(0, scrollbackRowCount - scrollOffset) : scrollbackRowCount
            let snapshotRows: [[TerminalViewportTextSnapshot.Cell]] = (0..<rows).map { row in
                let absoluteRow = firstAbsolute + row
                let isScrollbackRow = absoluteRow < scrollbackRowCount
                let scrollbackRow = isScrollbackRow ? (scrollback.getRow(at: absoluteRow) ?? []) : nil
                let gridRow = isScrollbackRow ? -1 : absoluteRow - scrollbackRowCount
                return (0..<cols).map { col in
                    let cell: Cell
                    if let scrollbackRow {
                        cell = col < scrollbackRow.count ? scrollbackRow[col] : .empty
                    } else {
                        cell = model.grid.cell(at: gridRow, col: col)
                    }
                    return TerminalViewportTextSnapshot.Cell(
                        codepoint: cell.codepoint,
                        width: max(Int(cell.width), 1),
                        isWideContinuation: cell.isWideContinuation
                    )
                }
            }
            return TerminalViewportTextSnapshot(
                rows: rows,
                cols: cols,
                scrollOffset: scrollOffset,
                cursorRow: model.cursor.row,
                cursorCol: model.cursor.col,
                cells: snapshotRows
            )
        }
    }

    private func enqueueCommittedTextIntent(
        kind: CommittedTextAnimationIntent.Kind,
        text: String,
        row: Int,
        col: Int,
        columnWidth: Int,
        cursorRow: Int?,
        cursorCol: Int?
    ) {
        guard let snapshot = currentViewportSnapshot() else { return }
        let now = CACurrentMediaTime()
        pendingCommittedTextIntents.append(
            CommittedTextAnimationIntent(
                kind: kind,
                text: text,
                row: row,
                col: col,
                columnWidth: columnWidth,
                cursorRow: cursorRow,
                cursorCol: cursorCol,
                capturedAt: now,
                expiresAt: now + PreviewPolicy.pendingIntentTimeout,
                baselineSnapshot: snapshot
            )
        )
        if pendingCommittedTextIntents.count > PreviewPolicy.maxCommittedTextPreviewCount {
            pendingCommittedTextIntents.removeFirst(
                pendingCommittedTextIntents.count - PreviewPolicy.maxCommittedTextPreviewCount
            )
        }
        ensurePendingIntentResolutionTimer()
    }

    private func resolvePendingCommittedTextIntentsIfNeeded() {
        guard outputConfirmedInputAnimationsEnabled,
              !pendingCommittedTextIntents.isEmpty,
              let currentSnapshot = currentViewportSnapshot() else {
            return
        }
        let now = CACurrentMediaTime()
        var remaining: [CommittedTextAnimationIntent] = []
        remaining.reserveCapacity(pendingCommittedTextIntents.count)
        for intent in pendingCommittedTextIntents {
            let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: currentSnapshot, now: now)
            switch evaluation {
            case .pending:
                remaining.append(intent)
            case .discard:
                continue
            case .matched(let match):
                showCommittedTextPreview(
                    text: match.text,
                    row: match.row,
                    col: match.col,
                    columnWidth: match.columnWidth,
                    cursorRow: match.cursorRow,
                    cursorCol: match.cursorCol,
                    kind: match.kind == .fadeIn ? .fadeIn : .fadeOut,
                    duration: match.kind == .fadeIn ? 0.20 : 0.34
                )
            }
        }
        pendingCommittedTextIntents = remaining
        if pendingCommittedTextIntents.isEmpty {
            pendingIntentResolutionTimer?.invalidate()
            pendingIntentResolutionTimer = nil
        } else {
            ensurePendingIntentResolutionTimer()
        }
    }

    private func deletionPreview(backward: Bool) -> (text: String, row: Int, col: Int, width: Int)? {
        guard let controller = terminalController else { return nil }
        if let modelPreview = controller.withModel({ model -> (text: String, row: Int, col: Int, width: Int)? in
            let row = model.cursor.row
            let baseCol = backward ? model.cursor.col - 1 : model.cursor.col
            guard row >= 0, row < model.rows, baseCol >= 0, baseCol < model.cols else { return nil }

            var targetCol = baseCol
            let cellAtBase = model.grid.cell(at: row, col: targetCol)
            if cellAtBase.isWideContinuation {
                targetCol = max(0, targetCol - 1)
            }

            let cell = model.grid.cell(at: row, col: targetCol)
            guard !cell.isWideContinuation,
                  cell.codepoint >= 0x20,
                  let scalar = UnicodeScalar(cell.codepoint) else {
                return nil
            }

            return (String(scalar), row, targetCol, max(Int(cell.width), 1))
        }) {
            return modelPreview
        }
        guard backward else { return nil }
        guard let recent = recentCommittedInsertions.last else { return nil }
        return (recent.text, recent.row, recent.col, recent.columnWidth)
    }

    private func showDeletionPreview(backward: Bool) {
        guard let preview = deletionPreview(backward: backward),
              shouldAnimateCommittedTextPreview(for: preview.text) else {
            return
        }
        showCommittedTextPreview(
            text: preview.text,
            row: preview.row,
            col: preview.col,
            columnWidth: preview.width,
            cursorRow: preview.row,
            cursorCol: preview.col,
            kind: .fadeOut,
            duration: 0.34
        )
    }

    private func committedTextPreviewFrameInterval() -> TimeInterval {
        window?.firstResponder === self ? (1.0 / 60.0) : (1.0 / 30.0)
    }
}

// MARK: - MTKViewDelegate

extension TerminalView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        updateTerminalSize()
    }

    func draw(in view: MTKView) {
        guard !renderingSuppressed,
              let renderer = renderer,
              let controller = terminalController else { return }
        RenderFPSMonitor.shared.recordFrame()
        lastDisplaySubmissionTime = CACurrentMediaTime()
        deferredDisplayUpdateWorkItem?.cancel()
        deferredDisplayUpdateWorkItem = nil

        let currentVersion = controller.currentRenderContentVersion
        if controller.isInInterruptCatchUpMode && currentVersion == lastDrawnRenderContentVersion {
            displayUpdateScheduled = false
            return
        }

        let highlight: MetalRenderer.SearchHighlight? = searchMatches.isEmpty ? nil :
            MetalRenderer.SearchHighlight(matches: searchMatches, currentIndex: currentSearchIndex)
        let linkUL: MetalRenderer.LinkUnderline? = hoveredLinkRange.map {
            MetalRenderer.LinkUnderline(row: $0.row, startCol: $0.startCol, endCol: $0.endCol)
        }

        let border = effectiveBorderConfig()
        let transientTextOverlays = activeTransientTextOverlaysForRendering()
        let suppressCursorBlink = !transientTextOverlays.isEmpty || !pendingCommittedTextIntents.isEmpty || hasMarkedText()
        // Capture the exact visible frame under the controller read lock, then
        // release the lock before vertex building and Metal submission.
        guard let snapshot = controller.captureRenderSnapshotIfAvailable() else {
            displayUpdateScheduled = false
            requestDisplayUpdate()
            return
        }
        renderer.render(
            snapshot: snapshot,
            selection: selection,
            searchHighlight: highlight,
            linkUnderline: linkUL,
            borderConfig: border,
            headerOverlayConfig: commandIdentityHeaderConfig(),
            transientTextOverlays: transientTextOverlays,
            suppressCursorBlink: suppressCursorBlink,
            in: view
        )
        pendingScrollSyncState = PendingScrollSyncState(
            scrollbackRowCount: snapshot.scrollbackRowCount,
            viewRows: snapshot.rows,
            scrollOffset: snapshot.scrollOffset,
            cellHeight: renderer.glyphAtlas.cellHeight
        )
        scheduleScrollerSyncIfNeeded()
        lastDrawnRenderContentVersion = snapshot.contentVersion
        scheduleIdleBufferRelease()
        displayUpdateScheduled = false
        if !isOutputActive,
           controller.currentRenderContentVersion != snapshot.contentVersion {
            requestDisplayUpdate()
        }
    }
}

// MARK: - NSTextInputClient

extension TerminalView {
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let controller = terminalController else { return }
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else if let plain = string as? String {
            text = plain
        } else {
            text = String(describing: string)
        }
        guard !text.isEmpty else { return }
        let previousMarkedString = markedTextStorage?.string
        let hadVisibleMarkedText = previousMarkedString != nil && !previousMarkedString!.isEmpty
        pendingTextInputHandled = true
        markedTextStorage = nil
        markedTextSelection = NSRange(location: NSNotFound, length: 0)
        clearDeferredMarkedTextOverlay()
        markedTextPreviewStartedAt = nil
        lastMarkedTextForAnimation = nil
        pendingMarkedTextContinuation = nil
        markedTextAnimatedSegment = nil
        destroyMarkedTextLayer()
        let shouldShowCommittedPreview = shouldAnimateCommittedTextPreview(for: text)
        if hadVisibleMarkedText && shouldShowCommittedPreview {
            let cursor = controller.withModel { $0.cursor }
            let width = columnWidth(for: text)
            if text == previousMarkedString {
                // Same text committed: hold at full alpha so it doesn't
                // flash while waiting for the grid to update via PTY.
                showCommittedTextPreview(
                    text: text,
                    row: cursor.row,
                    col: cursor.col,
                    columnWidth: width,
                    cursorRow: cursor.row,
                    cursorCol: cursor.col + width,
                    kind: .hold,
                    duration: 0.40
                )
            } else {
                // Converted (e.g. "かな" → "仮名"): fade out old, fade in new.
                showMarkedTextDeletionPreviews(
                    previous: previousMarkedString,
                    current: ""
                )
                showCommittedTextPreview(
                    text: text,
                    row: cursor.row,
                    col: cursor.col,
                    columnWidth: width,
                    cursorRow: cursor.row,
                    cursorCol: cursor.col + width,
                    kind: .fadeIn,
                    duration: 0.20
                )
            }
            if outputConfirmedInputAnimationsEnabled {
                enqueueCommittedInsertIntentIfNeeded(for: text)
            }
        } else if shouldShowCommittedPreview {
            if outputConfirmedInputAnimationsEnabled {
                enqueueCommittedInsertIntentIfNeeded(for: text)
            } else {
                showCommittedTextPreview(text)
            }
        }
        controller.sendInput(text)
        requestDisplayUpdate()
        queueInputFeedbackIfEnabled()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let attributed: NSAttributedString
        if let value = string as? NSAttributedString {
            attributed = value
        } else if let plain = string as? String {
            attributed = NSAttributedString(string: plain)
        } else {
            attributed = NSAttributedString(string: String(describing: string))
        }
        let previousText = markedTextStorage?.string
            ?? deferredMarkedTextOverlayStorage?.string
            ?? pendingMarkedTextContinuation
            ?? lastMarkedTextForAnimation
        let nextAnimatedSegment = animatedMarkedTextSegment(previous: previousText, current: attributed.string)
        let shouldRestartPreview = nextAnimatedSegment != nil
        pendingTextInputHandled = true
        clearCommittedInputAnimationState()
        clearDeferredMarkedTextOverlay()
        showMarkedTextDeletionPreviews(previous: previousText, current: attributed.string)
        markedTextStorage = NSMutableAttributedString(attributedString: attributed)
        markedTextSelection = selectedRange
        if shouldRestartPreview {
            markedTextPreviewStartedAt = CACurrentMediaTime()
        }
        markedTextAnimatedSegment = nextAnimatedSegment.map { ($0.text, $0.colOffset, markedTextPreviewStartedAt ?? CACurrentMediaTime()) }
        lastMarkedTextForAnimation = attributed.string
        pendingMarkedTextContinuation = nil
        updateMarkedTextOverlay()
        ensureTransientOverlayAnimationTimer()
        requestDisplayUpdate()
        if attributed.length > 0 {
            queueInputFeedbackIfEnabled()
        }
    }

    func unmarkText() {
        pendingMarkedTextContinuation = markedTextStorage?.string
        if let markedTextStorage, !markedTextStorage.string.isEmpty {
            deferredMarkedTextOverlayStorage = NSMutableAttributedString(attributedString: markedTextStorage)
            deferredMarkedTextOverlaySelection = markedTextSelection
            cancelDeferredMarkedTextOverlayClear()
            let clearWorkItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.deferredMarkedTextOverlayStorage = nil
                self.deferredMarkedTextOverlaySelection = NSRange(location: NSNotFound, length: 0)
                self.deferredMarkedTextOverlayClearWorkItem = nil
                self.updateMarkedTextOverlay()
                self.requestDisplayUpdate()
            }
            deferredMarkedTextOverlayClearWorkItem = clearWorkItem
            DispatchQueue.main.async(execute: clearWorkItem)
        }
        markedTextStorage = nil
        markedTextSelection = NSRange(location: NSNotFound, length: 0)
        markedTextPreviewStartedAt = nil
        markedTextAnimatedSegment = nil
        updateMarkedTextOverlay()
        ensureTransientOverlayAnimationTimer()
        requestDisplayUpdate()
    }

    func selectedRange() -> NSRange {
        markedTextSelection.location == NSNotFound ? NSRange(location: 0, length: 0) : markedTextSelection
    }

    func markedRange() -> NSRange {
        guard let markedTextStorage, markedTextStorage.length > 0 else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: markedTextStorage.length)
    }

    func hasMarkedText() -> Bool {
        (markedTextStorage?.length ?? 0) > 0
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let markedTextStorage, hasMarkedText() else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        let location = min(max(0, range.location), markedTextStorage.length)
        let length = min(max(0, range.length), markedTextStorage.length - location)
        let actual = NSRange(location: location, length: length)
        actualRange?.pointee = actual
        return markedTextStorage.attributedSubstring(from: actual)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.font, .foregroundColor, .underlineStyle]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = currentCursorRect()
        actualRange?.pointee = range
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    override func doCommand(by selector: Selector) {
        if !hasMarkedText() {
            switch selector {
            case #selector(NSResponder.deleteBackward(_:)):
                if outputConfirmedInputAnimationsEnabled,
                   let preview = deletionPreview(backward: true),
                   shouldAnimateCommittedTextPreview(for: preview.text) {
                    enqueueCommittedTextIntent(
                        kind: .deleteBackward,
                        text: preview.text,
                        row: preview.row,
                        col: preview.col,
                        columnWidth: preview.width,
                        cursorRow: preview.row,
                        cursorCol: preview.col
                    )
                } else {
                    showDeletionPreview(backward: true)
                }
            case #selector(NSResponder.deleteForward(_:)):
                if outputConfirmedInputAnimationsEnabled,
                   let preview = deletionPreview(backward: false),
                   shouldAnimateCommittedTextPreview(for: preview.text) {
                    enqueueCommittedTextIntent(
                        kind: .deleteForward,
                        text: preview.text,
                        row: preview.row,
                        col: preview.col,
                        columnWidth: preview.width,
                        cursorRow: preview.row,
                        cursorCol: preview.col
                    )
                } else {
                    showDeletionPreview(backward: false)
                }
            default:
                break
            }
        }
        pendingTextInputHandled = ensureKeyboardHandler()?.handleCommand(selector: selector) ?? false
    }
}

// MARK: - TerminalScrollView

/// NSScrollView wrapper that provides native macOS scrollbar behavior
/// for the terminal's virtual scrollback.
///
/// The scroll view doesn't actually scroll the MTKView — instead it
/// syncs the native NSScroller position with TerminalController's
/// scrollOffset, giving the user standard macOS scrollbar interaction
/// (drag, hover-expand, click-in-track) over virtual content.
///
/// IMPORTANT: The terminal view's frame is managed explicitly (no
/// autoresizingMask) to prevent deadlocks. Changing the document view's
/// frame height (to reflect scrollback size) must not trigger a resize
/// cascade that tries to re-acquire the TerminalController lock.
final class TerminalScrollView: NSScrollView {
    private struct ScrollSyncSignature: Equatable {
        let scrollbackRowCount: Int
        let viewRows: Int
        let scrollOffset: Int
        let viewportSize: NSSize
        let cellHeight: CGFloat
    }

    private enum Layout {
        static let backButtonInset: CGFloat = 10
        static let backButtonSize = NSSize(width: 30, height: 24)
    }

    /// The terminal view inside this scroll view.
    private(set) var terminalView: TerminalView!
    private let backButton = NSButton(title: "▦", target: nil, action: nil)
    var shortcutConfiguration: ShortcutConfiguration = .default {
        didSet {
            terminalView.shortcutConfiguration = shortcutConfiguration
        }
    }

    /// Guard against feedback loops during programmatic scroller updates.
    private var isSyncing = false
    private var lastScrollSyncSignature: ScrollSyncSignature?

    init(frame: NSRect, renderer: MetalRenderer) {
        super.init(frame: frame)

        // Configure scroll view for overlay-style scrollbar
        self.hasVerticalScroller = true
        self.hasHorizontalScroller = false
        self.autohidesScrollers = true
        self.scrollerStyle = .overlay
        self.verticalScroller?.knobStyle = .light
        self.drawsBackground = false
        self.borderType = .noBorder
        self.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        // Create the flipped container (NSScrollView needs a flipped documentView)
        let container = FlippedDocumentView(frame: NSRect(origin: .zero, size: frame.size))
        self.documentView = container

        // Create the terminal MTKView.
        // NO autoresizingMask — we manage its frame explicitly to prevent
        // resize cascades when the document view height changes for scrollbar sync.
        terminalView = TerminalView(frame: NSRect(origin: .zero, size: frame.size),
                                     renderer: renderer)
        terminalView.shortcutConfiguration = shortcutConfiguration
        container.addSubview(terminalView)

        backButton.bezelStyle = .texturedRounded
        backButton.isBordered = true
        backButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        backButton.contentTintColor = .white
        backButton.target = self
        backButton.action = #selector(backButtonPressed(_:))
        backButton.isHidden = true
        addSubview(backButton)

        // Observe scroll events from the native scroller (for knob drag)
        self.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: self.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layout

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        // Update document view width to match, keep height as-is (managed by syncScroller)
        documentView?.frame.size.width = bounds.width
        pinTerminalViewToViewport()
        layoutBackButton()
        lastScrollSyncSignature = nil
        terminalView?.refreshTerminalLayoutForCurrentBounds()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if shortcutConfiguration.matches(.backToIntegrated, event: event) {
            terminalView.onBackToIntegrated?()
            return true
        }
        if terminalView.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Keep the terminal MTKView pinned to the visible area.
    /// The MTKView must always fill exactly the viewport — it renders
    /// the virtual scroll position, not a physical offset.
    private func pinTerminalViewToViewport() {
        let targetFrame = NSRect(origin: contentView.bounds.origin,
                                 size: contentView.bounds.size)
        if terminalView.frame != targetFrame {
            terminalView.frame = targetFrame
        }
    }

    /// Force scroll-view geometry and terminal rows/cols to match immediately.
    func refreshViewportLayoutAndTerminalSize() {
        documentView?.frame.size.width = bounds.width
        pinTerminalViewToViewport()
        lastScrollSyncSignature = nil
        terminalView.refreshTerminalLayoutForCurrentBounds()
        syncScroller()
    }

    private func layoutBackButton() {
        backButton.frame = NSRect(
            x: Layout.backButtonInset,
            y: Layout.backButtonInset,
            width: Layout.backButtonSize.width,
            height: Layout.backButtonSize.height
        )
    }

    // MARK: - Scroller Sync

    /// Sync the native scroller position with the terminal's virtual scroll state.
    /// Called every frame from TerminalView's draw(in:).
    ///
    /// Handles two directions:
    /// 1. Programmatic → UI: when scrollOffset changes (auto-scroll on output,
    ///    keyboard scrollToBottom), update the clip view position.
    /// 2. Document height: when scrollback grows, update document view height
    ///    so the scroller knob proportion reflects total content.
    ///
    /// CRITICAL: All reads from TerminalController happen first (under lock),
    /// then the lock is released BEFORE any UI mutation. This prevents deadlocks
    /// caused by layout cascades (docView resize → terminalView resize →
    /// updateTerminalSize → controller.resize → lock).
    func syncScroller() {
        guard let controller = terminalView.terminalController,
              let renderer = terminalView.renderer else { return }

        let cellH = renderer.glyphAtlas.cellHeight
        guard cellH > 0 else { return }

        // Step 1: Read scroll state under lock — NO UI mutation here.
        let (sbCount, viewRows, scrollOffset) = controller.withViewport { model, scrollback, offset in
            (scrollback.rowCount, model.rows, offset)
        }
        // Lock is now released.

        let totalRows = sbCount + viewRows
        let viewportHeight = self.bounds.height
        let documentHeight = max(viewportHeight, CGFloat(totalRows) * cellH)
        let signature = ScrollSyncSignature(
            scrollbackRowCount: sbCount,
            viewRows: viewRows,
            scrollOffset: scrollOffset,
            viewportSize: bounds.size,
            cellHeight: cellH
        )
        let targetFrame = NSRect(origin: contentView.bounds.origin, size: contentView.bounds.size)
        if lastScrollSyncSignature == signature, terminalView.frame == targetFrame {
            return
        }

        // Step 2: All UI mutations under isSyncing to block re-entrant notifications.
        isSyncing = true
        defer { isSyncing = false }

        let docView = self.documentView!
        if abs(docView.frame.height - documentHeight) > 1 {
            docView.frame = NSRect(x: 0, y: 0, width: self.bounds.width, height: documentHeight)
            self.reflectScrolledClipView(self.contentView)
        }

        // Map scrollOffset to clipView position.
        // scrollOffset 0 = bottom → clipView origin.y = maxY
        // scrollOffset == sbCount = top → clipView origin.y = 0
        let maxY = documentHeight - viewportHeight
        let targetY: CGFloat
        if sbCount > 0 {
            targetY = maxY * CGFloat(sbCount - scrollOffset) / CGFloat(sbCount)
        } else {
            targetY = maxY
        }

        // Use cellH tolerance to avoid fighting with NSScrollView's native
        // scroll positioning (which differs by sub-line pixel amounts).
        let currentY = self.contentView.bounds.origin.y
        if abs(currentY - targetY) > cellH {
            self.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            self.reflectScrolledClipView(self.contentView)
        }

        pinTerminalViewToViewport()
        lastScrollSyncSignature = signature
    }

    func syncScroller(snapshot: TerminalController.RenderSnapshot, cellHeight: CGFloat) {
        syncScroller(
            scrollbackRowCount: snapshot.scrollbackRowCount,
            viewRows: snapshot.rows,
            scrollOffset: snapshot.scrollOffset,
            cellHeight: cellHeight
        )
    }

    func syncScroller(scrollbackRowCount sbCount: Int, viewRows: Int, scrollOffset: Int, cellHeight: CGFloat) {
        guard cellHeight > 0 else { return }

        let totalRows = sbCount + viewRows
        let viewportHeight = bounds.height
        let documentHeight = max(viewportHeight, CGFloat(totalRows) * cellHeight)
        let signature = ScrollSyncSignature(
            scrollbackRowCount: sbCount,
            viewRows: viewRows,
            scrollOffset: scrollOffset,
            viewportSize: bounds.size,
            cellHeight: cellHeight
        )
        let targetFrame = NSRect(origin: contentView.bounds.origin, size: contentView.bounds.size)
        if lastScrollSyncSignature == signature, terminalView.frame == targetFrame {
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        let docView = self.documentView!
        if abs(docView.frame.height - documentHeight) > 1 {
            docView.frame = NSRect(x: 0, y: 0, width: self.bounds.width, height: documentHeight)
            self.reflectScrolledClipView(self.contentView)
        }

        let maxY = documentHeight - viewportHeight
        let targetY: CGFloat
        if sbCount > 0 {
            targetY = maxY * CGFloat(sbCount - scrollOffset) / CGFloat(sbCount)
        } else {
            targetY = maxY
        }

        let currentY = self.contentView.bounds.origin.y
        if abs(currentY - targetY) > cellHeight {
            self.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            self.reflectScrolledClipView(self.contentView)
        }

        pinTerminalViewToViewport()
        lastScrollSyncSignature = signature
    }

    /// Handle user-initiated scrolling (scroll wheel, trackpad, knob drag).
    /// NSScrollView moves the clip view natively; we translate that position
    /// back to a scrollOffset for the terminal's virtual scrollback.
    @objc private func scrollViewDidScroll(_ notification: Notification) {
        guard !isSyncing else { return }
        guard let controller = terminalView.terminalController else { return }

        let viewportHeight = bounds.height
        let documentHeight = documentView?.frame.height ?? viewportHeight
        let maxY = documentHeight - viewportHeight
        guard maxY > 0 else { return }

        let currentY = contentView.bounds.origin.y
        let fraction = currentY / maxY  // 0 = top, 1 = bottom

        let sbCount = controller.withViewport { _, scrollback, _ in scrollback.rowCount }
        let newOffset = sbCount - Int(fraction * CGFloat(sbCount))
        controller.setScrollOffset(newOffset)
        lastScrollSyncSignature = nil

        pinTerminalViewToViewport()
        if terminalView.renderingSuppressed,
           let splitContainer = terminalView.enclosingScrollView?.superview as? SplitTerminalContainerView {
            splitContainer.requestRender()
        }
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        return window?.makeFirstResponder(terminalView) ?? false
    }

    @objc private func backButtonPressed(_ sender: Any?) {
        terminalView.onBackToIntegrated?()
    }
}

/// Flipped document view so NSScrollView's origin is at the top.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let terminalView = subviews.first(where: { $0 is TerminalView }),
           terminalView.frame.contains(point) {
            return terminalView
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let terminalView = subviews.first(where: { $0 is TerminalView }) as? TerminalView else {
            super.mouseDown(with: event)
            return
        }
        terminalView.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let terminalView = subviews.first(where: { $0 is TerminalView }) as? TerminalView else {
            super.mouseDragged(with: event)
            return
        }
        terminalView.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let terminalView = subviews.first(where: { $0 is TerminalView }) as? TerminalView else {
            super.mouseUp(with: event)
            return
        }
        terminalView.mouseUp(with: event)
    }
}

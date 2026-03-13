import AppKit
import MetalKit

/// Transparent NSScrollView overlay that provides native macOS scrollbar behavior.
/// Only intercepts events targeting the scrollers; all other events pass through
/// to the view below (IntegratedView).
final class ScrollbarOverlayView: NSScrollView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let scrollers handle their own events (hover expand, knob drag, etc.)
        let hit = super.hitTest(point)
        if hit is NSScroller { return hit }
        // Pass through everything else to views below
        return nil
    }
}

/// Flipped NSView used as the documentView inside the scroll overlay.
final class ScrollDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Displays all terminal sessions as a grid of live thumbnails.
///
/// Each thumbnail renders its terminal content at full PTY grid resolution,
/// scaled down by the GPU to fit the thumbnail cell. Clicking a thumbnail
/// switches to the focused (occupied) view. Shift+click enables multi-select
/// for split display.
final class IntegratedView: MTKView, NSDraggingSource {
    static func overviewBackgroundClearColor() -> MTLClearColor {
        MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
    }

    private struct LayoutGeometryCacheKey: Equatable {
        let boundsSize: NSSize
        let explicitWorkspaceNames: [String]
        let terminalIDs: [UUID]
        let workspaceNames: [String]
    }

    private struct WorkspaceSection {
        let name: String
        let terminals: [TerminalController]
    }

    private struct ThumbnailLayout {
        let controller: TerminalController
        let thumbnail: NSRect
        let title: NSRect
        let close: NSRect
        let workspace: String
    }

    private struct WorkspaceLayout {
        let name: String
        let frame: NSRect
        let headerFrame: NSRect
        let addFrame: NSRect
        let closeFrame: NSRect
        let selectAllFrame: NSRect
        let deselectFrame: NSRect
        let terminals: [ThumbnailLayout]
    }

    private struct TextVertexCacheKey: Hashable {
        let text: String
        let glyphScaleBits: UInt32
        let colorBits: (UInt32, UInt32, UInt32, UInt32)

        func hash(into hasher: inout Hasher) {
            hasher.combine(text)
            hasher.combine(glyphScaleBits)
            hasher.combine(colorBits.0)
            hasher.combine(colorBits.1)
            hasher.combine(colorBits.2)
            hasher.combine(colorBits.3)
        }

        static func == (lhs: TextVertexCacheKey, rhs: TextVertexCacheKey) -> Bool {
            lhs.text == rhs.text &&
                lhs.glyphScaleBits == rhs.glyphScaleBits &&
                lhs.colorBits.0 == rhs.colorBits.0 &&
                lhs.colorBits.1 == rhs.colorBits.1 &&
                lhs.colorBits.2 == rhs.colorBits.2 &&
                lhs.colorBits.3 == rhs.colorBits.3
        }
    }

    private struct CachedTextVertices {
        let vertices: [Float]
        let width: Float

        var byteCount: Int {
            vertices.count * MemoryLayout<Float>.stride
        }

        var storageByteCount: Int {
            vertices.capacity * MemoryLayout<Float>.stride
        }
    }

    private struct ThumbnailSurfaceSignature: Hashable {
        let rows: Int
        let cols: Int
        let scrollbackRowCount: Int
        let scrollOffset: Int
        let contentVersion: UInt64
        let fontName: String
        let fontSizeBits: UInt64
        let glyphScaleBits: UInt32
        let thumbnailWidthBits: UInt64
        let thumbnailHeightBits: UInt64
        let defaultForegroundBits: (UInt32, UInt32, UInt32)
        let defaultBackgroundBits: (UInt32, UInt32, UInt32, UInt32)

        init(
            rows: Int,
            cols: Int,
            scrollbackRowCount: Int,
            scrollOffset: Int,
            contentVersion: UInt64,
            fontName: String,
            fontSize: Double,
            glyphScale: Float,
            thumbnailSize: NSSize,
            terminalAppearance: MetalRenderer.TerminalAppearance
        ) {
            self.rows = rows
            self.cols = cols
            self.scrollbackRowCount = scrollbackRowCount
            self.scrollOffset = scrollOffset
            self.contentVersion = contentVersion
            self.fontName = fontName
            self.fontSizeBits = fontSize.bitPattern
            self.glyphScaleBits = glyphScale.bitPattern
            self.thumbnailWidthBits = Double(thumbnailSize.width).bitPattern
            self.thumbnailHeightBits = Double(thumbnailSize.height).bitPattern
            self.defaultForegroundBits = (
                terminalAppearance.defaultForeground.r.bitPattern,
                terminalAppearance.defaultForeground.g.bitPattern,
                terminalAppearance.defaultForeground.b.bitPattern
            )
            self.defaultBackgroundBits = (
                terminalAppearance.defaultBackground.r.bitPattern,
                terminalAppearance.defaultBackground.g.bitPattern,
                terminalAppearance.defaultBackground.b.bitPattern,
                terminalAppearance.defaultBackground.a.bitPattern
            )
        }

        static func == (lhs: ThumbnailSurfaceSignature, rhs: ThumbnailSurfaceSignature) -> Bool {
            lhs.rows == rhs.rows &&
                lhs.cols == rhs.cols &&
                lhs.scrollbackRowCount == rhs.scrollbackRowCount &&
                lhs.scrollOffset == rhs.scrollOffset &&
                lhs.contentVersion == rhs.contentVersion &&
                lhs.fontName == rhs.fontName &&
                lhs.fontSizeBits == rhs.fontSizeBits &&
                lhs.glyphScaleBits == rhs.glyphScaleBits &&
                lhs.thumbnailWidthBits == rhs.thumbnailWidthBits &&
                lhs.thumbnailHeightBits == rhs.thumbnailHeightBits &&
                lhs.defaultForegroundBits.0 == rhs.defaultForegroundBits.0 &&
                lhs.defaultForegroundBits.1 == rhs.defaultForegroundBits.1 &&
                lhs.defaultForegroundBits.2 == rhs.defaultForegroundBits.2 &&
                lhs.defaultBackgroundBits.0 == rhs.defaultBackgroundBits.0 &&
                lhs.defaultBackgroundBits.1 == rhs.defaultBackgroundBits.1 &&
                lhs.defaultBackgroundBits.2 == rhs.defaultBackgroundBits.2 &&
                lhs.defaultBackgroundBits.3 == rhs.defaultBackgroundBits.3
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(rows)
            hasher.combine(cols)
            hasher.combine(scrollbackRowCount)
            hasher.combine(scrollOffset)
            hasher.combine(contentVersion)
            hasher.combine(fontName)
            hasher.combine(fontSizeBits)
            hasher.combine(glyphScaleBits)
            hasher.combine(thumbnailWidthBits)
            hasher.combine(thumbnailHeightBits)
            hasher.combine(defaultForegroundBits.0)
            hasher.combine(defaultForegroundBits.1)
            hasher.combine(defaultForegroundBits.2)
            hasher.combine(defaultBackgroundBits.0)
            hasher.combine(defaultBackgroundBits.1)
            hasher.combine(defaultBackgroundBits.2)
            hasher.combine(defaultBackgroundBits.3)
        }
    }

    private struct CachedThumbnailSurface {
        let signature: ThumbnailSurfaceSignature
        let texture: MTLTexture

        var byteCount: Int {
            texture.width * texture.height * 4
        }
    }

    private struct CachedCPUStatus {
        let pid: pid_t
        let shellPID: pid_t
        let text: String?
    }

    private struct TextAtlasSignature: Equatable {
        let fontName: String
        let fontSize: CGFloat
        let scaleFactor: CGFloat
    }

    /// Terminal manager
    private let manager: TerminalManager

    /// Metal renderer
    private let renderer: MetalRenderer

    /// Callback: user clicked a terminal thumbnail (single select).
    var onSelectTerminal: ((TerminalController) -> Void)?

    var onAddWorkspace: (() -> Void)?
    var onAddTerminalToWorkspace: ((String) -> Void)?
    var onRemoveWorkspace: ((String) -> Void)?
    var onRemoveTerminal: ((TerminalController) -> Void)?
    var onRenameWorkspace: ((String, String) -> Void)?
    var onMoveTerminalToWorkspace: ((TerminalController, String) -> Void)?
    var onRenameTerminalTitle: ((TerminalController, String?) -> Void)?

    /// Set of currently selected terminals (for multi-select with Shift)
    private(set) var selectedTerminals: Set<UUID> = []

    /// Whether the Shift key is currently held (for showing select/deselect buttons)
    private var isShiftDown = false

    /// Resets multi-select state (e.g. when returning to integrated view).
    func clearSelection() {
        selectedTerminals.removeAll()
        setNeedsDisplay(bounds)
    }

    func selectAllTerminals() {
        let allTerminals = manager.terminals
        guard !allTerminals.isEmpty else { return }
        if allTerminals.count >= 2 {
            onMultiSelect?(allTerminals)
        } else if let single = allTerminals.first {
            onSelectTerminal?(single)
        }
    }

    /// Callback: user shift-clicked multiple terminals for split view.
    var onMultiSelect: (([TerminalController]) -> Void)?

    /// CPU usage provider for status labels.
    var cpuUsageProvider: ((pid_t) -> Double?)?

    /// Terminals that are actively producing output (border pulses red).
    private(set) var activeOutputTerminals: Set<UUID> = [] {
        didSet {
            guard oldValue != activeOutputTerminals else { return }
            updateRenderLoopState()
            setNeedsDisplay(bounds)
        }
    }

    @discardableResult
    func setTerminalOutputActive(_ terminalID: UUID, isActive: Bool) -> Bool {
        if isActive {
            let inserted = activeOutputTerminals.insert(terminalID).inserted
            return inserted
        }
        return activeOutputTerminals.remove(terminalID) != nil
    }

    func noteTerminalOutputActivity(_ terminalID: UUID) {
        thumbnailSurfaceCache.removeValue(forKey: terminalID)
        let inserted = setTerminalOutputActive(terminalID, isActive: true)
        scheduleOverviewContentRedraw(forceImmediate: inserted)
    }

    func noteTerminalContentActivity(_ terminalID: UUID) {
        thumbnailSurfaceCache.removeValue(forKey: terminalID)
        scheduleOverviewContentRedraw(forceImmediate: false)
    }

    var debugHasOutputPulseTimer: Bool { outputPulseTimer != nil }
    var debugHasOutputContentRedrawTimer: Bool { outputContentRedrawTimer != nil }

    var shortcutConfiguration: ShortcutConfiguration = .default
    var explicitWorkspaceNames: [String] = [] {
        didSet {
            invalidateLayoutCache()
            setNeedsDisplay(bounds)
        }
    }

    /// Cached × icon texture for close buttons (r8Unorm, same as glyph atlas)
    private var closeIconTexture: MTLTexture?
    /// Cached circle texture for close button background (r8Unorm)
    private var closeCircleTexture: MTLTexture?
    /// Size in pixels of the cached icon textures
    private static let closeIconTextureSize: Int = 64
    private static let closeButtonInsetPoints: CGFloat = 0.75

    /// Custom tooltip window for instant display
    private var tooltipWindow: NSWindow?
    private var tooltipLabel: NSTextField?
    private var currentTooltipText: String?

    var hasTooltipWindow: Bool { tooltipWindow != nil }
    var hasCloseTextures: Bool { closeIconTexture != nil || closeCircleTexture != nil }

    /// Tracking area for mouse hover (close buttons, etc.)
    private var trackingArea: NSTrackingArea?

    /// Index of the thumbnail currently under the mouse (for hover effects)
    private var hoveredIndex: Int?

    /// ID of the terminal whose close button is hovered
    private var hoveredCloseID: UUID?
    /// Name of the workspace whose close button is hovered
    private var hoveredWorkspaceClose: String?

    /// Stored frame for the add button (updated each draw)
    private var addWorkspaceButtonFrame: NSRect = .zero
    private var cachedWorkspaceLayouts: [WorkspaceLayout] = []
    private var mouseDownPoint: NSPoint?
    private var mouseDownTerminal: TerminalController?
    private var mouseDownWorkspace: String?

    /// Vertical scroll state
    private var scrollOffset: CGFloat = 0
    private var totalContentHeight: CGFloat = 0

    /// Drag reorder callbacks
    var onReorderTerminal: ((TerminalController, String, Int) -> Void)?
    var onReorderWorkspace: ((String, Int) -> Void)?

    /// Drag reorder visual indicators
    private var dragInsertionIndicator: NSRect?
    private var dragWorkspaceIndicator: NSRect?

    /// Pasteboard types for drag
    private static let terminalPasteboardType = NSPasteboard.PasteboardType("com.pterm.terminal-id")
    private static let workspacePasteboardType = NSPasteboard.PasteboardType("com.pterm.workspace-name")

    /// Companion NSScrollView overlay for native macOS scrollbar behavior.
    /// The scroll view is placed on top of this view and passes through
    /// all events except those targeting its scrollers.
    weak var companionScrollView: NSScrollView? {
        didSet { updateCompanionScrollObservation(oldValue: oldValue, newValue: companionScrollView) }
    }

    /// Auto-scroll during drag near edges
    private var dragAutoScrollTimer: Timer?
    private static let dragAutoScrollEdge: CGFloat = 60
    private static let dragAutoScrollSpeed: CGFloat = 24
    private var companionScrollObserver: NSObjectProtocol?
    private var cachedLayoutGeometryKey: LayoutGeometryCacheKey?
    private var cachedLayoutScrollOffset: CGFloat?
    private var cachedBaseWorkspaceLayouts: [WorkspaceLayout] = []
    private var cachedBaseFlattenedThumbnails: [ThumbnailLayout] = []
    private var cachedVisibleWorkspaceLayouts: [WorkspaceLayout] = []
    private var cachedFlattenedThumbnails: [ThumbnailLayout] = []
    private var cachedVisibleThumbnails: [ThumbnailLayout] = []
    private var textVertexCache: [TextVertexCacheKey: CachedTextVertices] = [:]
    private var textAtlasSignature: TextAtlasSignature?
    private var thumbnailSurfaceCache: [UUID: CachedThumbnailSurface] = [:]
    private var cachedCPUStatusByTerminalID: [UUID: CachedCPUStatus] = [:]
    private var stagingPreContentOverlayVertices: [Float] = []
    private var stagingPostContentOverlayVertices: [Float] = []
    private var stagingThumbnailBgVertices: [Float] = []
    private var stagingThumbnailGlyphVertices: [Float] = []
    private var stagingAtlasGlyphVertices: [Float] = []
    private var stagingIconVertices: [Float] = []
    private var stagingCircleVertices: [Float] = []
    private var thumbnailCacheBuildBgScratch: [Float] = []
    private var thumbnailCacheBuildGlyphScratch: [Float] = []
    private var scrollInteractionTimer: Timer?
    private var idleBufferReleaseTimer: Timer?
    private var outputPulseTimer: Timer?
    private var outputContentRedrawTimer: Timer?
    private var lastOutputContentRedrawTime: CFTimeInterval = 0
    private var overviewOutputDisplayRequestCount = 0
    private var isOverviewScrolling = false

    /// Layout constants
    private struct Layout {
        static let thumbnailPadding: CGFloat = 12
        static let workspacePadding: CGFloat = 16
        static let workspaceHeaderHeight: CGFloat = 28
        static let titleBarHeight: CGFloat = 24
        static let closeButtonSize: CGFloat = 16
        static let addButtonSize: CGFloat = 40
        static let cornerRadius: CGFloat = 6
        static let titleFontSize: CGFloat = 11
        static let borderWidth: CGFloat = 1.5
        static let selectedBorderWidth: CGFloat = 3.0
        static let workspaceBorderWidth: CGFloat = 1.0
        /// Thumbnail aspect ratio (4:3).
        static let thumbnailAspectRatio: CGFloat = 320.0 / 240.0
        /// Thumbnail width bounds (points).
        static let thumbnailMinWidth: CGFloat = 80
        static let thumbnailMaxWidth: CGFloat = 320
    }

    private struct CachePolicy {
        static let textVertexSoftLimit = 256
        static let textVertexSoftByteLimit = 2 * 1024 * 1024
        static let textVertexMinimumSoftByteLimit = 256 * 1024
        static let textVertexBytesPerVisibleTerminal = 32 * 1024
        static let textVertexIdleByteLimit = 256 * 1024
        static let thumbnailVertexFloor = 8
        static let thumbnailVertexPerPreferredTerminal = 2
        static let thumbnailVertexSoftByteLimit = 12 * 1024 * 1024
        static let thumbnailVertexMinimumSoftByteLimit = 1 * 1024 * 1024
        static let thumbnailVertexBytesPerPreferredTerminal = 128 * 1024
        static let thumbnailVertexIdleByteLimit = 1 * 1024 * 1024
    }

    static func effectiveTextVertexSoftByteLimit(visibleTerminalCount: Int) -> Int {
        let dynamicBudget = max(
            CachePolicy.textVertexMinimumSoftByteLimit,
            max(visibleTerminalCount, 1) * CachePolicy.textVertexBytesPerVisibleTerminal
        )
        return min(CachePolicy.textVertexSoftByteLimit, dynamicBudget)
    }

    static func effectiveThumbnailVertexSoftLimit(preferredTerminalCount: Int) -> Int {
        max(
            CachePolicy.thumbnailVertexFloor,
            preferredTerminalCount * CachePolicy.thumbnailVertexPerPreferredTerminal
        )
    }

    static func effectiveThumbnailVertexSoftByteLimit(preferredTerminalCount: Int) -> Int {
        let dynamicBudget = max(
            CachePolicy.thumbnailVertexMinimumSoftByteLimit,
            max(preferredTerminalCount, 1) * CachePolicy.thumbnailVertexBytesPerPreferredTerminal
        )
        return min(CachePolicy.thumbnailVertexSoftByteLimit, dynamicBudget)
    }

    static func effectiveOutputContentRedrawInterval(visibleTerminalCount: Int) -> TimeInterval {
        let clampedVisibleCount = max(1, visibleTerminalCount)
        let scaledInterval = 0.25 + Double(clampedVisibleCount - 1) * 0.15
        return min(1.0, max(0.25, scaledInterval))
    }

    var cachedTextVertexCount: Int { textVertexCache.count }
    var cachedThumbnailVertexCount: Int { thumbnailSurfaceCache.count }
    func debugHasThumbnailSurfaceCacheEntry(for controllerID: UUID) -> Bool {
        thumbnailSurfaceCache[controllerID] != nil
    }
    func debugCachedThumbnailSurfaceOpaquePixelCount(for controllerID: UUID) -> Int? {
        guard let texture = thumbnailSurfaceCache[controllerID]?.texture else { return nil }
        return debugOpaquePixelCount(in: texture)
    }
    func debugCachedThumbnailSurfaceMaximumAlpha(for controllerID: UUID) -> UInt8? {
        guard let cached = thumbnailSurfaceCache[controllerID] else { return nil }
        let scaleFactor = Float(renderer.glyphAtlas.scaleFactor)
        let thumbnailSize = NSSize(
            width: Double(bitPattern: cached.signature.thumbnailWidthBits),
            height: Double(bitPattern: cached.signature.thumbnailHeightBits)
        )
        guard let readableTexture = makeReadableOverviewThumbnailTexture(size: thumbnailSize, scaleFactor: scaleFactor),
              let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            return nil
        }
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: cached.texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: cached.texture.width, height: cached.texture.height, depth: 1),
                to: readableTexture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return debugMaximumAlpha(in: readableTexture)
    }
    var cachedCPUStatusCount: Int { cachedCPUStatusByTerminalID.count }
    var cachedTextVertexBytes: Int { textVertexCache.values.reduce(0) { $0 + $1.byteCount } }
    var cachedThumbnailVertexBytes: Int { thumbnailSurfaceCache.values.reduce(0) { $0 + $1.byteCount } }
    func debugCachedThumbnailSurfaceContentVersion(for controllerID: UUID) -> UInt64? {
        thumbnailSurfaceCache[controllerID]?.signature.contentVersion
    }
    var cachedTextVertexStorageBytes: Int { textVertexCache.values.reduce(0) { $0 + $1.storageByteCount } }
    var cachedThumbnailVertexStorageBytes: Int { cachedThumbnailVertexBytes }
    var cachedWorkspaceLayoutCount: Int { cachedWorkspaceLayouts.count }
    var cachedFlattenedThumbnailCount: Int { cachedFlattenedThumbnails.count }
    var cachedVisibleWorkspaceLayoutCount: Int { cachedVisibleWorkspaceLayouts.count }
    var cachedVisibleThumbnailCount: Int { cachedVisibleThumbnails.count }
    var debugOverviewOutputDisplayRequestCount: Int { overviewOutputDisplayRequestCount }
    var stagingVertexStorageBytes: Int {
        [
            stagingPreContentOverlayVertices,
            stagingPostContentOverlayVertices,
            stagingThumbnailBgVertices,
            stagingThumbnailGlyphVertices,
            stagingAtlasGlyphVertices,
            stagingIconVertices,
            stagingCircleVertices,
            thumbnailCacheBuildBgScratch,
            thumbnailCacheBuildGlyphScratch
        ].reduce(0) { partial, vertices in
            partial + vertices.capacity * MemoryLayout<Float>.stride
        }
    }

    func debugPrimeTextVertexCache(texts: [String], scaleFactor: Float = 2.0) {
        for text in texts {
            _ = cachedTextVertices(
                for: text,
                scaleFactor: scaleFactor,
                glyphScale: 0.8,
                color: Self.uiSecondaryTitleTextColor(alpha: 1.0)
            )
        }
    }

    func debugAppendTransientTextVertices(
        text: String,
        scaleFactor: Float = 2.0,
        glyphScale: Float = 0.8,
        color: (Float, Float, Float, Float)? = nil
    ) -> Int {
        var vertices: [Float] = []
        appendTextVertices(
            text: text,
            scaleFactor: scaleFactor,
            glyphScale: glyphScale,
            color: color ?? Self.uiSecondaryTitleTextColor(alpha: 1.0),
            originX: 0,
            originY: 0,
            useCache: false,
            to: &vertices
        )
        return vertices.count
    }

    func debugSeedCPUStatusCache(
        controllerID: UUID,
        pid: pid_t = 1,
        shellPID: pid_t = 1,
        text: String? = "CPU: 17.3%"
    ) {
        cacheCPUStatus(
            controllerID: controllerID,
            pid: pid,
            shellPID: shellPID,
            text: text
        )
    }

    func debugPrimeThumbnailVertexCache(scaleFactor: Float = 2.0) {
        updateLayoutCacheIfNeeded()
        for layout in cachedFlattenedThumbnails {
            _ = thumbnailSurface(
                for: layout.controller,
                thumbnailSize: layout.thumbnail.size,
                scaleFactor: scaleFactor,
                commandBuffer: nil
            )
        }
    }

    func debugSeedThumbnailSurfaceCacheForTesting(controllerID: UUID) {
        guard let texture = renderer.makeOverviewThumbnailTexture(size: NSSize(width: 8, height: 8), scaleFactor: 1.0) else {
            return
        }
        let signature = ThumbnailSurfaceSignature(
            rows: 1,
            cols: 1,
            scrollbackRowCount: 0,
            scrollOffset: 0,
            contentVersion: 0,
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize),
            glyphScale: 1.0,
            thumbnailSize: NSSize(width: 8, height: 8),
            terminalAppearance: renderer.terminalAppearance
        )
        thumbnailSurfaceCache[controllerID] = CachedThumbnailSurface(signature: signature, texture: texture)
    }

    func debugRenderedThumbnailOpaquePixelCount(for controllerID: UUID) -> Int? {
        updateLayoutCacheIfNeeded()
        guard let layout = cachedFlattenedThumbnails.first(where: { $0.controller.id == controllerID }) else {
            return nil
        }
        let scaleFactor = Float(renderer.glyphAtlas.scaleFactor)
        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer(),
              let renderTexture = renderer.makeOverviewThumbnailTexture(size: layout.thumbnail.size, scaleFactor: scaleFactor),
              let readableTexture = makeReadableOverviewThumbnailTexture(size: layout.thumbnail.size, scaleFactor: scaleFactor) else {
            return nil
        }
        _ = layout.controller.withViewport { model, scrollback, scrollOffset in
            renderer.renderThumbnailToTexture(
                model: model,
                scrollback: scrollback,
                scrollOffset: scrollOffset,
                texture: renderTexture,
                thumbnailSize: layout.thumbnail.size,
                scaleFactor: scaleFactor,
                commandBuffer: commandBuffer
            )
        }
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: renderTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: renderTexture.width, height: renderTexture.height, depth: 1),
                to: readableTexture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return debugOpaquePixelCount(in: readableTexture)
    }

    func debugRenderedThumbnailMaximumAlpha(for controllerID: UUID) -> UInt8? {
        updateLayoutCacheIfNeeded()
        guard let layout = cachedFlattenedThumbnails.first(where: { $0.controller.id == controllerID }) else {
            return nil
        }
        let scaleFactor = Float(renderer.glyphAtlas.scaleFactor)
        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer(),
              let readableTexture = makeReadableOverviewThumbnailTexture(size: layout.thumbnail.size, scaleFactor: scaleFactor) else {
            return nil
        }
        layout.controller.withViewport { model, scrollback, scrollOffset in
            renderer.renderThumbnailToTexture(
                model: model,
                scrollback: scrollback,
                scrollOffset: scrollOffset,
                texture: readableTexture,
                thumbnailSize: layout.thumbnail.size,
                scaleFactor: scaleFactor,
                commandBuffer: commandBuffer
            )
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return debugMaximumAlpha(in: readableTexture)
    }

    func debugThumbnailVertexCounts(for controllerID: UUID) -> (background: Int, glyph: Int)? {
        updateLayoutCacheIfNeeded()
        guard let layout = cachedFlattenedThumbnails.first(where: { $0.controller.id == controllerID }) else {
            return nil
        }
        let scaleFactor = Float(renderer.glyphAtlas.scaleFactor)
        return layout.controller.withViewport { model, scrollback, scrollOffset in
            var bgVertices: [Float] = []
            var glyphVertices: [Float] = []
            renderer.appendThumbnailVertexData(
                model: model,
                scrollback: scrollback,
                scrollOffset: scrollOffset,
                thumbnailRect: layout.thumbnail,
                scaleFactor: scaleFactor,
                bgVertices: &bgVertices,
                glyphVertices: &glyphVertices
            )
            return (
                background: bgVertices.count / 12,
                glyph: glyphVertices.count / 12
            )
        }
    }

    func debugThumbnailGlyphBounds(for controllerID: UUID) -> (minX: Float, minY: Float, maxX: Float, maxY: Float)? {
        debugThumbnailVertexBounds(for: controllerID, includeGlyphs: true)
    }

    func debugThumbnailBackgroundBounds(for controllerID: UUID) -> (minX: Float, minY: Float, maxX: Float, maxY: Float)? {
        debugThumbnailVertexBounds(for: controllerID, includeGlyphs: false)
    }

    private func debugThumbnailVertexBounds(for controllerID: UUID, includeGlyphs: Bool) -> (minX: Float, minY: Float, maxX: Float, maxY: Float)? {
        updateLayoutCacheIfNeeded()
        guard let layout = cachedFlattenedThumbnails.first(where: { $0.controller.id == controllerID }) else {
            return nil
        }
        let scaleFactor = Float(renderer.glyphAtlas.scaleFactor)
        return layout.controller.withViewport { model, scrollback, scrollOffset in
            var bgVertices: [Float] = []
            var glyphVertices: [Float] = []
            renderer.appendThumbnailVertexData(
                model: model,
                scrollback: scrollback,
                scrollOffset: scrollOffset,
                thumbnailRect: NSRect(origin: .zero, size: layout.thumbnail.size),
                scaleFactor: scaleFactor,
                bgVertices: &bgVertices,
                glyphVertices: &glyphVertices
            )
            let vertices = includeGlyphs ? glyphVertices : bgVertices
            guard !vertices.isEmpty else { return nil }
            var minX = Float.greatestFiniteMagnitude
            var minY = Float.greatestFiniteMagnitude
            var maxX = -Float.greatestFiniteMagnitude
            var maxY = -Float.greatestFiniteMagnitude
            var index = 0
            while index < vertices.count {
                let x = vertices[index]
                let y = vertices[index + 1]
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                index += 12
            }
            return (minX, minY, maxX, maxY)
        }
    }

    func debugThumbnailLayout(for controllerID: UUID) -> NSSize? {
        updateLayoutCacheIfNeeded()
        return cachedFlattenedThumbnails.first(where: { $0.controller.id == controllerID })?.thumbnail.size
    }

    func debugRenderedOverviewOpaquePixelCount(in rect: NSRect) -> Int? {
        syncScaleFactorIfNeeded()
        let drawableSize = self.drawableSize
        guard drawableSize.width > 0,
              drawableSize.height > 0,
              let texture = makeReadableOverviewTexture(drawableSize: drawableSize),
              let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            return nil
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        renderOverviewScene(
            renderPassDescriptor: renderPassDescriptor,
            commandBuffer: commandBuffer,
            drawableSize: drawableSize
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return debugOpaquePixelCount(in: texture, clippedTo: rect, scaleFactor: Float(renderer.glyphAtlas.scaleFactor))
    }

    func debugEnsureLayoutCache() {
        updateLayoutCacheIfNeeded()
    }

    func debugReleaseLayoutStorageForTesting() {
        releaseLayoutStorage()
    }

    func debugInstallTooltipWindowForTesting() {
        showTooltip("Test", at: NSPoint(x: 8, y: 8))
    }

    private func makeReadableOverviewThumbnailTexture(size: NSSize, scaleFactor: Float) -> MTLTexture? {
        let width = max(1, Int(ceil(size.width * CGFloat(scaleFactor))))
        let height = max(1, Int(ceil(size.height * CGFloat(scaleFactor))))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalRenderer.renderTargetPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        return renderer.device.makeTexture(descriptor: descriptor)
    }

    private func makeReadableOverviewTexture(drawableSize: CGSize) -> MTLTexture? {
        let width = max(1, Int(drawableSize.width))
        let height = max(1, Int(drawableSize.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalRenderer.renderTargetPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        return renderer.device.makeTexture(descriptor: descriptor)
    }

    private func debugOpaquePixelCount(in texture: MTLTexture) -> Int? {
        debugOpaquePixelCount(in: texture, clippedTo: nil, scaleFactor: 1.0)
    }

    private func debugOpaquePixelCount(in texture: MTLTexture, clippedTo rect: NSRect?, scaleFactor: Float) -> Int? {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        var opaquePixels = 0
        let clippedRect: NSRect
        if let rect {
            clippedRect = rect
        } else {
            clippedRect = NSRect(x: 0, y: 0, width: CGFloat(texture.width) / CGFloat(scaleFactor), height: CGFloat(texture.height) / CGFloat(scaleFactor))
        }
        let startX = max(0, Int(floor(clippedRect.minX * CGFloat(scaleFactor))))
        let endX = min(texture.width, Int(ceil(clippedRect.maxX * CGFloat(scaleFactor))))
        let startY = max(0, Int(floor(clippedRect.minY * CGFloat(scaleFactor))))
        let endY = min(texture.height, Int(ceil(clippedRect.maxY * CGFloat(scaleFactor))))
        guard startX < endX, startY < endY else { return 0 }

        for y in startY..<endY {
            var index = y * bytesPerRow + startX * 4 + 3
            let rowEnd = y * bytesPerRow + endX * 4
            while index < rowEnd {
                if bytes[index] > 8 {
                    opaquePixels += 1
                }
                index += 4
            }
        }
        return opaquePixels
    }

    private func debugMaximumAlpha(in texture: MTLTexture) -> UInt8? {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        var maximum: UInt8 = 0
        var index = 3
        while index < bytes.count {
            maximum = max(maximum, bytes[index])
            index += 4
        }
        return maximum
    }

    func debugPrimeCloseTexturesForTesting() {
        _ = ensureCloseIconTexture()
        _ = ensureCloseCircleTexture()
    }

    func debugInsertOversizedTextVertexCacheEntry(text: String, floatCount: Int) {
        let key = TextVertexCacheKey(
            text: text,
            glyphScaleBits: Float(1).bitPattern,
            colorBits: (Float(1).bitPattern, Float(1).bitPattern, Float(1).bitPattern, Float(1).bitPattern)
        )
        textVertexCache[key] = CachedTextVertices(vertices: Array(repeating: 1, count: floatCount), width: 0)
    }

    func debugInsertOversizedThumbnailVertexCacheEntries(floatCountPerEntry: Int) {
        updateLayoutCacheIfNeeded()
        for layout in cachedFlattenedThumbnails {
            let controller = layout.controller
            let signature = ThumbnailSurfaceSignature(
                rows: 24,
                cols: 80,
                scrollbackRowCount: 0,
                scrollOffset: 0,
                contentVersion: controller.thumbnailContentVersion,
                fontName: renderer.glyphAtlas.fontName,
                fontSize: renderer.glyphAtlas.fontSize,
                glyphScale: 1,
                thumbnailSize: layout.thumbnail.size,
                terminalAppearance: renderer.terminalAppearance
            )
            let pixels = max(1, floatCountPerEntry / 16)
            let side = max(1, Int(ceil(sqrt(Double(pixels)))))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: MetalRenderer.renderTargetPixelFormat,
                width: side,
                height: side,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .private
            let texture = renderer.device.makeTexture(descriptor: descriptor)!
            thumbnailSurfaceCache[controller.id] = CachedThumbnailSurface(signature: signature, texture: texture)
        }
    }

    // MARK: - Initialization

    init(frame: NSRect, renderer: MetalRenderer, manager: TerminalManager) {
        self.renderer = renderer
        self.manager = manager

        super.init(frame: frame, device: renderer.device)

        self.delegate = self
        self.preferredFramesPerSecond = 12
        self.colorPixelFormat = MetalRenderer.renderTargetPixelFormat
        self.clearColor = Self.overviewBackgroundClearColor()
        self.framebufferOnly = true
        self.isPaused = true
        self.enableSetNeedsDisplay = true
        self.wantsLayer = true
        self.layer?.isOpaque = false
        self.layer?.backgroundColor = NSColor.clear.cgColor
        applyRenderTargetColorSpace()
        self.registerForDraggedTypes([.string, Self.terminalPasteboardType, Self.workspacePasteboardType])

        updateTrackingArea()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        if let companionScrollObserver {
            NotificationCenter.default.removeObserver(companionScrollObserver)
        }
        scrollInteractionTimer?.invalidate()
        idleBufferReleaseTimer?.invalidate()
        outputPulseTimer?.invalidate()
        outputContentRedrawTimer?.invalidate()
        releaseStagingVertexStorage()
        renderer.removeBuffers(for: self)
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Multi-Display Support

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncScaleFactor()
        invalidateLayoutCache()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncScaleFactor()
        invalidateLayoutCache()
    }

    func syncScaleFactorIfNeeded() {
        syncScaleFactor()
    }

    func applyAppearanceSettings() {
        clearColor = Self.overviewBackgroundClearColor()
        setNeedsDisplay(bounds)
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
        guard activeOutputTerminals.isEmpty, !isOverviewScrolling else { return }
        purgeRebuildableCachesIfNeeded(force: false)
        releaseLayoutStorage()
        releaseStagingVertexStorage()
        releaseAuxiliaryOverviewResources()
        renderer.releaseOverviewBuffers(for: self)
        _ = renderer.compactIdleGlyphAtlas()
        drawableSize = .zero
    }

    func debugReleaseIdleBuffersNow() {
        releaseIdleReusableBuffersNow()
    }

    func releaseInactiveRenderingResourcesNow() {
        idleBufferReleaseTimer?.invalidate()
        idleBufferReleaseTimer = nil
        purgeRebuildableCachesIfNeeded(force: true)
        releaseLayoutStorage()
        releaseStagingVertexStorage()
        releaseAuxiliaryOverviewResources()
        renderer.releaseOverviewBuffers(for: self)
        _ = renderer.compactIdleGlyphAtlas(maximumInactiveGenerations: 0)
        drawableSize = .zero
    }

    func compactForMemoryPressureNow() {
        idleBufferReleaseTimer?.invalidate()
        idleBufferReleaseTimer = nil
        purgeRebuildableCachesIfNeeded(force: true)
        releaseLayoutStorage()
        releaseStagingVertexStorage()
        releaseAuxiliaryOverviewResources()
        renderer.releaseOverviewBuffers(for: self)
        _ = renderer.compactIdleGlyphAtlas(maximumInactiveGenerations: 0)
    }

    func terminalListDidChange() {
        idleBufferReleaseTimer?.invalidate()
        idleBufferReleaseTimer = nil
        let activeTerminalIDs = Set(manager.terminals.map(\.id))
        selectedTerminals.formIntersection(activeTerminalIDs)
        if activeTerminalIDs.isEmpty {
            cachedCPUStatusByTerminalID.removeAll()
            textVertexCache.removeAll()
            thumbnailSurfaceCache.removeAll()
            releaseLayoutStorage()
            releaseStagingVertexStorage()
            renderer.releaseOverviewBuffers(for: self)
        }
        invalidateLayoutCache()
        updateLayoutCacheIfNeeded()
        syncCompanionDocumentView()
        updateRenderLoopState()
        setNeedsDisplay(bounds)
    }

    private func syncScaleFactor() {
        let newScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        applyRenderTargetColorSpace()
        if newScale != renderer.glyphAtlas.scaleFactor {
            renderer.glyphAtlas.updateScaleFactor(newScale)
        }
        // Ensure drawable matches Retina pixel dimensions
        let expectedSize = CGSize(width: bounds.width * newScale, height: bounds.height * newScale)
        if drawableSize != .zero,
           (abs(drawableSize.width - expectedSize.width) > 1 || abs(drawableSize.height - expectedSize.height) > 1) {
            drawableSize = expectedSize
        }
    }

    private func ensureDrawableStorageAllocatedIfNeeded() {
        guard drawableSize == .zero else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let expectedSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard expectedSize.width > 0, expectedSize.height > 0 else { return }
        drawableSize = expectedSize
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateLayoutCache()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        invalidateLayoutCache()
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        ensureDrawableStorageAllocatedIfNeeded()
        super.setNeedsDisplay(invalidRect)
    }

    // MARK: - Tracking Area

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    // MARK: - Layout

    private func workspaceSections(from terminals: [TerminalController]) -> [WorkspaceSection] {
        let grouped = Dictionary(grouping: terminals) { controller in
            let name = controller.sessionSnapshot.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Uncategorized" : name
        }
        let explicit = explicitWorkspaceNames.map {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Uncategorized" : trimmed
        }

        var orderedNames: [String] = []
        var seen = Set<String>()

        for name in explicit where !seen.contains(name) {
            seen.insert(name)
            orderedNames.append(name)
        }

        for controller in terminals {
            let trimmed = controller.sessionSnapshot.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "Uncategorized" : trimmed
            if !seen.contains(name) {
                seen.insert(name)
                orderedNames.append(name)
            }
        }

        return orderedNames.map { WorkspaceSection(name: $0, terminals: grouped[$0] ?? []) }
    }

    private func workspaceLayouts(from sections: [WorkspaceSection]) -> [WorkspaceLayout] {
        guard !sections.isEmpty else {
            totalContentHeight = 0
            return []
        }

        let outerPad = Layout.workspacePadding
        let innerPad = Layout.thumbnailPadding
        let viewWidth = bounds.width
        let aspect = Layout.thumbnailAspectRatio
        let maxW = Layout.thumbnailMaxWidth
        let minW = Layout.thumbnailMinWidth

        // Compute global thumbnail size (used as the upper bound for per-workspace sizing):
        // Determine column count so that thumbnails are ≤ maxWidth, then compute exact width.
        let fullContentWidth = viewWidth - outerPad * 2 - innerPad * 2
        let maxCellWidth = maxW + innerPad
        let fitCols = max(1, Int(ceil(fullContentWidth / maxCellWidth)))
        let thumbWidth = max(minW, min(maxW, (fullContentWidth - innerPad * CGFloat(fitCols)) / CGFloat(fitCols)))
        let cellWidth = thumbWidth + innerPad

        // Phase 1: group workspaces into rows that fit within window width
        struct RowItem {
            let sectionIndex: Int
            let gridCols: Int
            let gridRows: Int
            let naturalWidth: CGFloat
        }
        var rows: [[RowItem]] = []
        var currentRow: [RowItem] = []
        var currentRowWidth: CGFloat = outerPad

        for (i, section) in sections.enumerated() {
            let terminalCount = max(section.terminals.count, 1)
            let gridCols = Int(ceil(sqrt(Double(terminalCount))))
            let gridRows = Int(ceil(Double(terminalCount) / Double(gridCols)))
            let naturalWidth = CGFloat(gridCols) * cellWidth + innerPad * 2

            let neededWidth = currentRowWidth + naturalWidth + outerPad
            if !currentRow.isEmpty && neededWidth > viewWidth {
                rows.append(currentRow)
                currentRow = []
                currentRowWidth = outerPad
            }
            currentRow.append(RowItem(sectionIndex: i, gridCols: gridCols, gridRows: gridRows, naturalWidth: naturalWidth))
            currentRowWidth += naturalWidth + outerPad
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        // Helper: compute actual grid dimensions for a workspace given its allocated width.
        // Maximizes columns (up to terminal count) while keeping thumbnail width within [minW, maxW].
        // More terminals → more columns → narrower thumbnails.
        func actualGrid(terminalCount: Int, wsWidth: CGFloat) -> (cols: Int, rows: Int, thumbW: CGFloat, thumbH: CGFloat) {
            let wsContentW = wsWidth - innerPad * 2
            let minCellWidth = minW + innerPad
            // Maximum columns that fit at minimum thumbnail width
            let maxFitCols = max(1, Int(floor(wsContentW / minCellWidth)))
            // Use at most the terminal count
            let cols = max(1, min(terminalCount, maxFitCols))
            let tw = max(minW, min(maxW, (wsContentW - innerPad * CGFloat(cols)) / CGFloat(cols)))
            let th = tw / aspect
            let rows = Int(ceil(Double(terminalCount) / Double(cols)))
            return (cols, rows, tw, th)
        }

        // Phase 2: compute total content height (using actual workspace widths)
        var rowHeights: [CGFloat] = []
        for row in rows {
            let totalNatural = row.map(\.naturalWidth).reduce(0, +)
            let totalPad = outerPad * CGFloat(row.count + 1)
            let availableW = viewWidth - totalPad

            var maxContentHeight: CGFloat = 0
            for item in row {
                let wsW = totalNatural > 0
                    ? availableW * (item.naturalWidth / totalNatural)
                    : availableW / CGFloat(row.count)
                let termCount = max(sections[item.sectionIndex].terminals.count, 1)
                let g = actualGrid(terminalCount: termCount, wsWidth: wsW)
                let wsCellH = g.thumbH + Layout.titleBarHeight + innerPad
                let h = CGFloat(g.rows) * wsCellH
                if h > maxContentHeight { maxContentHeight = h }
            }
            let rowHeight = max(Layout.workspaceHeaderHeight + innerPad * 1.5 + maxContentHeight + innerPad, 140)
            rowHeights.append(rowHeight)
        }

        let rawContentHeight = outerPad + rowHeights.reduce(0, +) + CGFloat(rows.count - 1) * outerPad + outerPad + Layout.addButtonSize + outerPad
        totalContentHeight = rawContentHeight

        // Clamp scroll offset
        let maxScroll = max(0, totalContentHeight - bounds.height)
        if scrollOffset > maxScroll { scrollOffset = maxScroll }
        if scrollOffset < 0 { scrollOffset = 0 }

        // Phase 3: compute layouts with scroll offset applied
        var layouts: [WorkspaceLayout] = []
        var currentY = outerPad

        for (rowIndex, row) in rows.enumerated() {
            let rowHeight = rowHeights[rowIndex]
            let totalNaturalWidth = row.map(\.naturalWidth).reduce(0, +)
            let totalPadding = outerPad * CGFloat(row.count + 1)
            let availableForWorkspaces = viewWidth - totalPadding

            var currentX = outerPad
            for item in row {
                let section = sections[item.sectionIndex]
                let wsWidth = totalNaturalWidth > 0
                    ? availableForWorkspaces * (item.naturalWidth / totalNaturalWidth)
                    : availableForWorkspaces / CGFloat(row.count)
                let frame = NSRect(x: currentX, y: currentY, width: wsWidth, height: rowHeight)
                let headerFrame = NSRect(x: frame.minX + innerPad,
                                         y: frame.minY + innerPad / 2,
                                         width: frame.width - innerPad * 2,
                                         height: Layout.workspaceHeaderHeight)
                let closeFrame = NSRect(x: headerFrame.minX + 4,
                                        y: headerFrame.minY + (headerFrame.height - Layout.closeButtonSize) / 2,
                                        width: Layout.closeButtonSize,
                                        height: Layout.closeButtonSize)
                let addFrame = NSRect(x: headerFrame.maxX - Layout.closeButtonSize - 6,
                                      y: headerFrame.minY + (headerFrame.height - Layout.closeButtonSize) / 2,
                                      width: Layout.closeButtonSize,
                                      height: Layout.closeButtonSize)
                // Compute grid and thumbnail size based on actual workspace width
                let termCount = max(section.terminals.count, 1)
                let g = actualGrid(terminalCount: termCount, wsWidth: wsWidth)
                let wsCellWidth = g.thumbW + innerPad
                let wsCellHeight = g.thumbH + Layout.titleBarHeight + innerPad

                let contentHeight = max(0, CGFloat(g.rows) * wsCellHeight)
                let contentFrame = NSRect(x: frame.minX + innerPad,
                                          y: headerFrame.maxY + innerPad / 2,
                                          width: frame.width - innerPad * 2,
                                          height: contentHeight)

                var thumbnailLayouts: [ThumbnailLayout] = []
                for (index, controller) in section.terminals.enumerated() {
                    let gridCol = index % g.cols
                    let gridRow = index / g.cols
                    let thumbX = contentFrame.minX + CGFloat(gridCol) * wsCellWidth + innerPad / 2
                    let thumbY = contentFrame.minY + CGFloat(gridRow) * wsCellHeight + innerPad / 2
                    let titleFrame = NSRect(x: thumbX, y: thumbY,
                                            width: g.thumbW, height: Layout.titleBarHeight)
                    let thumbFrame = NSRect(x: thumbX, y: titleFrame.maxY,
                                            width: g.thumbW, height: g.thumbH)
                    let closeBtn = NSRect(
                        x: titleFrame.origin.x + 4,
                        y: titleFrame.origin.y + (Layout.titleBarHeight - Layout.closeButtonSize) / 2,
                        width: Layout.closeButtonSize,
                        height: Layout.closeButtonSize
                    )
                    thumbnailLayouts.append(ThumbnailLayout(
                        controller: controller,
                        thumbnail: thumbFrame,
                        title: titleFrame,
                        close: closeBtn,
                        workspace: section.name
                    ))
                }

                // "Select All" / "Deselect" buttons at bottom-right of workspace
                let selectBtnH: CGFloat = Layout.titleBarHeight
                let selectAllW: CGFloat = 70
                let deselectW: CGFloat = 60
                let selectBtnY = frame.maxY - innerPad - selectBtnH
                let selectAllFrame = NSRect(x: frame.maxX - innerPad - selectAllW,
                                            y: selectBtnY, width: selectAllW, height: selectBtnH)
                let deselectFrame = NSRect(x: selectAllFrame.minX - 4 - deselectW,
                                           y: selectBtnY, width: deselectW, height: selectBtnH)

                layouts.append(WorkspaceLayout(name: section.name, frame: frame, headerFrame: headerFrame,
                                               addFrame: addFrame, closeFrame: closeFrame,
                                               selectAllFrame: selectAllFrame, deselectFrame: deselectFrame,
                                               terminals: thumbnailLayouts))
                currentX += wsWidth + outerPad
            }
            currentY += rowHeight + outerPad
        }

        return layouts
    }

    private func invalidateLayoutCache() {
        cachedLayoutGeometryKey = nil
        cachedLayoutScrollOffset = nil
        cachedBaseWorkspaceLayouts = []
        cachedBaseFlattenedThumbnails = []
        cachedWorkspaceLayouts = []
        cachedVisibleWorkspaceLayouts = []
        cachedFlattenedThumbnails = []
        cachedVisibleThumbnails = []
    }

    private func pruneThumbnailVertexCache(activeTerminalIDs: Set<UUID>, preferredTerminalIDs: Set<UUID>) {
        guard !thumbnailSurfaceCache.isEmpty else { return }
        let originalCount = thumbnailSurfaceCache.count
        thumbnailSurfaceCache = thumbnailSurfaceCache.filter { activeTerminalIDs.contains($0.key) }
        let softLimit = Self.effectiveThumbnailVertexSoftLimit(preferredTerminalCount: preferredTerminalIDs.count)
        let softByteLimit = Self.effectiveThumbnailVertexSoftByteLimit(preferredTerminalCount: preferredTerminalIDs.count)
        if thumbnailSurfaceCache.count > softLimit || cachedThumbnailVertexBytes > softByteLimit {
            thumbnailSurfaceCache = thumbnailSurfaceCache.filter { preferredTerminalIDs.contains($0.key) }
        }
        if thumbnailSurfaceCache.count > softLimit || cachedThumbnailVertexBytes > softByteLimit {
            thumbnailSurfaceCache.removeAll()
        }
        if thumbnailSurfaceCache.count < originalCount {
            renderer.releaseOverviewBuffers(for: self)
        }
    }

    private func pruneCPUStatusCache(activeTerminalIDs: Set<UUID>) {
        guard !cachedCPUStatusByTerminalID.isEmpty else { return }
        cachedCPUStatusByTerminalID = cachedCPUStatusByTerminalID.filter { activeTerminalIDs.contains($0.key) }
    }

    private func cacheCPUStatus(
        controllerID: UUID,
        pid: pid_t,
        shellPID: pid_t,
        text: String?
    ) {
        guard let text else {
            cachedCPUStatusByTerminalID.removeValue(forKey: controllerID)
            return
        }
        cachedCPUStatusByTerminalID[controllerID] = CachedCPUStatus(pid: pid, shellPID: shellPID, text: text)
    }

    private func pruneTextVertexCacheIfNeeded() {
        let visibleTerminalCount = cachedVisibleThumbnails.count
        let softByteLimit = Self.effectiveTextVertexSoftByteLimit(visibleTerminalCount: visibleTerminalCount)
        guard textVertexCache.count > CachePolicy.textVertexSoftLimit ||
                cachedTextVertexBytes > softByteLimit else { return }
        textVertexCache.removeAll()
        renderer.releaseOverviewBuffers(for: self)
    }

    private func purgeRebuildableCachesIfNeeded(force: Bool) {
        let activeTerminalIDs = Set(manager.terminals.map(\.id))
        pruneCPUStatusCache(activeTerminalIDs: activeTerminalIDs)

        if force || !cachedCPUStatusByTerminalID.isEmpty {
            cachedCPUStatusByTerminalID.removeAll()
        }

        if force || !textVertexCache.isEmpty {
            textVertexCache.removeAll()
        }

        if force || !thumbnailSurfaceCache.isEmpty {
            thumbnailSurfaceCache.removeAll()
        }
    }

    private func releaseLayoutStorage() {
        cachedLayoutGeometryKey = nil
        cachedLayoutScrollOffset = nil
        cachedBaseWorkspaceLayouts = []
        cachedBaseFlattenedThumbnails = []
        cachedWorkspaceLayouts = []
        cachedVisibleWorkspaceLayouts = []
        cachedFlattenedThumbnails = []
        cachedVisibleThumbnails = []
    }

    private func releaseStagingVertexStorage() {
        stagingPreContentOverlayVertices = []
        stagingPostContentOverlayVertices = []
        stagingThumbnailBgVertices = []
        stagingThumbnailGlyphVertices = []
        stagingAtlasGlyphVertices = []
        stagingIconVertices = []
        stagingCircleVertices = []
        thumbnailCacheBuildBgScratch = []
        thumbnailCacheBuildGlyphScratch = []
    }

    private func releaseAuxiliaryOverviewResources() {
        hideTooltip()
        closeIconTexture = nil
        closeCircleTexture = nil
    }

    private func trimStagingVertexStorageAfterDraw() {
        if activeOutputTerminals.isEmpty && !isOverviewScrolling {
            releaseStagingVertexStorage()
            return
        }

        stagingPreContentOverlayVertices.removeAll(keepingCapacity: true)
        stagingPostContentOverlayVertices.removeAll(keepingCapacity: true)
        stagingThumbnailGlyphVertices.removeAll(keepingCapacity: true)
        stagingAtlasGlyphVertices.removeAll(keepingCapacity: true)
        stagingIconVertices.removeAll(keepingCapacity: true)
        stagingCircleVertices.removeAll(keepingCapacity: true)
        thumbnailCacheBuildBgScratch.removeAll(keepingCapacity: true)
        thumbnailCacheBuildGlyphScratch.removeAll(keepingCapacity: true)
    }

    private func beginOverviewScrollInteraction() {
        let wasScrolling = isOverviewScrolling
        isOverviewScrolling = true
        scrollInteractionTimer?.invalidate()
        scrollInteractionTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.isOverviewScrolling = false
            self.updateRenderLoopState()
            self.setNeedsDisplay(self.bounds)
        }
        if !wasScrolling {
            hideTooltip()
            updateRenderLoopState()
        }
    }

    private func invalidateTextVertexCacheIfNeeded() {
        let signature = TextAtlasSignature(
            fontName: renderer.glyphAtlas.fontName,
            fontSize: renderer.glyphAtlas.fontSize,
            scaleFactor: renderer.glyphAtlas.scaleFactor
        )
        guard textAtlasSignature != signature else { return }
        textAtlasSignature = signature
        textVertexCache.removeAll()
        renderer.releaseOverviewBuffers(for: self)
    }

    private func updateLayoutCacheIfNeeded() {
        let terminals = manager.terminals
        let activeTerminalIDs = Set(terminals.map(\.id))
        pruneCPUStatusCache(activeTerminalIDs: activeTerminalIDs)
        let workspaceNames = terminals.map {
            let trimmed = $0.sessionSnapshot.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Uncategorized" : trimmed
        }
        let geometryKey = LayoutGeometryCacheKey(
            boundsSize: bounds.size,
            explicitWorkspaceNames: explicitWorkspaceNames,
            terminalIDs: terminals.map(\.id),
            workspaceNames: workspaceNames
        )

        if cachedLayoutGeometryKey != geometryKey {
            let sections = workspaceSections(from: terminals)
            let layouts = workspaceLayouts(from: sections)
            cachedLayoutGeometryKey = geometryKey
            cachedBaseWorkspaceLayouts = layouts
            cachedBaseFlattenedThumbnails = layouts.flatMap(\.terminals)
            cachedLayoutScrollOffset = nil
        }

        if cachedLayoutScrollOffset == scrollOffset,
           !cachedWorkspaceLayouts.isEmpty || cachedBaseWorkspaceLayouts.isEmpty {
            return
        }

        cachedLayoutScrollOffset = scrollOffset
        cachedWorkspaceLayouts = cachedBaseWorkspaceLayouts.map {
            translatedWorkspaceLayout($0, yOffset: -scrollOffset)
        }
        cachedFlattenedThumbnails = cachedWorkspaceLayouts.flatMap(\.terminals)
        cachedVisibleWorkspaceLayouts = cachedWorkspaceLayouts.filter { $0.frame.intersects(bounds) }
        cachedVisibleThumbnails = cachedVisibleWorkspaceLayouts.flatMap { workspace in
            workspace.terminals.filter { $0.title.union($0.thumbnail).intersects(bounds) }
        }
        let preferredTerminalIDs = Set(
            cachedVisibleThumbnails.map(\.controller.id)
        )
        .union(activeOutputTerminals)
        .union(selectedTerminals)
        .union(hoveredCloseID.map { [$0] } ?? [])
        .union(hoveredIndex.flatMap { index in
            guard index < cachedFlattenedThumbnails.count else { return nil }
            return [cachedFlattenedThumbnails[index].controller.id]
        } ?? [])
        pruneThumbnailVertexCache(
            activeTerminalIDs: activeTerminalIDs,
            preferredTerminalIDs: preferredTerminalIDs
        )
        pruneTextVertexCacheIfNeeded()
    }

    private func translatedWorkspaceLayout(_ layout: WorkspaceLayout, yOffset: CGFloat) -> WorkspaceLayout {
        WorkspaceLayout(
            name: layout.name,
            frame: layout.frame.offsetBy(dx: 0, dy: yOffset),
            headerFrame: layout.headerFrame.offsetBy(dx: 0, dy: yOffset),
            addFrame: layout.addFrame.offsetBy(dx: 0, dy: yOffset),
            closeFrame: layout.closeFrame.offsetBy(dx: 0, dy: yOffset),
            selectAllFrame: layout.selectAllFrame.offsetBy(dx: 0, dy: yOffset),
            deselectFrame: layout.deselectFrame.offsetBy(dx: 0, dy: yOffset),
            terminals: layout.terminals.map { translatedThumbnailLayout($0, yOffset: yOffset) }
        )
    }

    private func translatedThumbnailLayout(_ layout: ThumbnailLayout, yOffset: CGFloat) -> ThumbnailLayout {
        ThumbnailLayout(
            controller: layout.controller,
            thumbnail: layout.thumbnail.offsetBy(dx: 0, dy: yOffset),
            title: layout.title.offsetBy(dx: 0, dy: yOffset),
            close: layout.close.offsetBy(dx: 0, dy: yOffset),
            workspace: layout.workspace
        )
    }

    private func thumbnailSurface(
        for controller: TerminalController,
        thumbnailSize: NSSize,
        scaleFactor: Float,
        commandBuffer: MTLCommandBuffer?
    ) -> CachedThumbnailSurface? {
        let fontSettings = controller.persistedFontSettings
        return controller.withViewport { model, scrollback, scrollOffset in
            let signature = ThumbnailSurfaceSignature(
                rows: model.rows,
                cols: model.cols,
                scrollbackRowCount: scrollback.rowCount,
                scrollOffset: scrollOffset,
                contentVersion: controller.thumbnailContentVersion,
                fontName: fontSettings.name,
                fontSize: fontSettings.size,
                glyphScale: scaleFactor,
                thumbnailSize: thumbnailSize,
                terminalAppearance: renderer.terminalAppearance
            )
            if let cached = thumbnailSurfaceCache[controller.id], cached.signature == signature {
                return cached
            }
            guard let commandBuffer else {
                return thumbnailSurfaceCache[controller.id]
            }
            let texture = thumbnailSurfaceCache[controller.id]?.texture
                ?? renderer.makeOverviewThumbnailTexture(size: thumbnailSize, scaleFactor: scaleFactor)
            guard let texture else { return nil }
            renderer.renderThumbnailToTexture(
                model: model,
                scrollback: scrollback,
                scrollOffset: scrollOffset,
                texture: texture,
                thumbnailSize: thumbnailSize,
                scaleFactor: scaleFactor,
                commandBuffer: commandBuffer
            )
            let cached = CachedThumbnailSurface(signature: signature, texture: texture)
            thumbnailSurfaceCache[controller.id] = cached
            pruneThumbnailVertexCache(
                activeTerminalIDs: Set(manager.terminals.map(\.id)),
                preferredTerminalIDs: Set(cachedVisibleThumbnails.map(\.controller.id))
            )
            return cached
        }
    }

    /// Return the index of the thumbnail at the given view-coordinates point.
    /// Only matches the thumbnail content area, NOT the title bar.
    private func thumbnailIndex(at point: NSPoint) -> Int? {
        for (index, layout) in cachedFlattenedThumbnails.enumerated() {
            if layout.thumbnail.contains(point) {
                return index
            }
        }
        return nil
    }

    /// Return the index of the thumbnail whose title OR thumbnail area contains the point.
    /// Used for hover effects and drag initiation (but NOT for navigation).
    private func thumbnailOrTitleIndex(at point: NSPoint) -> Int? {
        for (index, layout) in cachedFlattenedThumbnails.enumerated() {
            if layout.title.union(layout.thumbnail).contains(point) {
                return index
            }
        }
        return nil
    }

    /// Check if a point hits a close button, returning the associated controller.
    private func closeButtonController(at point: NSPoint) -> TerminalController? {
        for f in cachedFlattenedThumbnails {
            let hitRect = f.close.insetBy(dx: -4, dy: -4)
            if hitRect.contains(point) {
                return f.controller
            }
        }
        return nil
    }

    private func workspaceAddTarget(at point: NSPoint) -> String? {
        for layout in cachedWorkspaceLayouts where layout.addFrame.insetBy(dx: -4, dy: -4).contains(point) {
            return layout.name
        }
        return nil
    }

    private func workspaceRemoveTarget(at point: NSPoint) -> String? {
        for layout in cachedWorkspaceLayouts where layout.closeFrame.insetBy(dx: -4, dy: -4).contains(point) {
            return layout.name
        }
        return nil
    }

    private func workspaceHeaderTarget(at point: NSPoint) -> String? {
        for layout in cachedWorkspaceLayouts where layout.headerFrame.contains(point) {
            return layout.name
        }
        return nil
    }

    private func terminalTitleTarget(at point: NSPoint) -> TerminalController? {
        for layout in cachedFlattenedThumbnails where layout.title.contains(point) && !layout.close.insetBy(dx: -4, dy: -4).contains(point) {
            return layout.controller
        }
        return nil
    }

    // MARK: - Flipped Coordinates

    override var isFlipped: Bool { true }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        prepareLayoutForInteractionIfNeeded()
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        mouseDownTerminal = nil
        mouseDownWorkspace = nil

        if addWorkspaceButtonFrame.contains(point) {
            onAddWorkspace?()
            return
        }

        if let workspace = workspaceAddTarget(at: point) {
            onAddTerminalToWorkspace?(workspace)
            return
        }

        if let workspace = workspaceRemoveTarget(at: point) {
            onRemoveWorkspace?(workspace)
            return
        }

        if event.clickCount == 2,
           let workspace = workspaceHeaderTarget(at: point),
           workspaceAddTarget(at: point) == nil,
           workspaceRemoveTarget(at: point) == nil {
            promptRenameWorkspace(workspace)
            return
        }

        if event.clickCount == 2,
           let controller = terminalTitleTarget(at: point) {
            promptRenameTerminalTitle(controller)
            return
        }

        // Check close button first
        if let controller = closeButtonController(at: point) {
            guard let onRemoveTerminal else {
                assertionFailure("IntegratedView.onRemoveTerminal must be configured before handling terminal removal")
                return
            }
            onRemoveTerminal(controller)
            return
        }

        // Check "Select All" / "Deselect" buttons (only visible when Shift is held)
        if isShiftDown {
            for workspace in cachedWorkspaceLayouts {
                if workspace.selectAllFrame.contains(point) {
                    for tl in workspace.terminals {
                        selectedTerminals.insert(tl.controller.id)
                    }
                    setNeedsDisplay(bounds)
                    return
                }
                let hasSelection = workspace.terminals.contains { selectedTerminals.contains($0.controller.id) }
                if hasSelection && workspace.deselectFrame.contains(point) {
                    for tl in workspace.terminals {
                        selectedTerminals.remove(tl.controller.id)
                    }
                    setNeedsDisplay(bounds)
                    return
                }
            }
        }

        // Check thumbnail or title click: record for drag or click-up navigation
        if let idx = thumbnailOrTitleIndex(at: point), idx < cachedFlattenedThumbnails.count {
            let controller = cachedFlattenedThumbnails[idx].controller
            mouseDownTerminal = controller

            if event.modifierFlags.contains(.shift) {
                // Multi-select with Shift: toggle selection (immediate)
                if selectedTerminals.contains(controller.id) {
                    selectedTerminals.remove(controller.id)
                } else {
                    selectedTerminals.insert(controller.id)
                }
                setNeedsDisplay(bounds)
                mouseDownTerminal = nil  // Don't navigate on mouse up
            }
            // Non-shift click: navigation deferred to mouseUp
            return
        }

        // Workspace header click: prepare for workspace drag
        if let workspace = workspaceHeaderTarget(at: point),
           workspaceAddTarget(at: point) == nil,
           workspaceRemoveTarget(at: point) == nil {
            mouseDownWorkspace = workspace
            mouseDownPoint = point
        }
    }

    override func mouseUp(with event: NSEvent) {
        prepareLayoutForInteractionIfNeeded()
        defer {
            mouseDownTerminal = nil
            mouseDownPoint = nil
        }
        guard let controller = mouseDownTerminal else { return }

        // Navigate only if the click lands on the thumbnail content area (not the title bar)
        let point = convert(event.locationInWindow, from: nil)
        if let idx = thumbnailIndex(at: point) {
            if idx < cachedFlattenedThumbnails.count && cachedFlattenedThumbnails[idx].controller === controller {
                selectedTerminals.removeAll()
                onSelectTerminal?(controller)
            }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let shiftNow = event.modifierFlags.contains(.shift)
        if shiftNow != isShiftDown {
            isShiftDown = shiftNow
            setNeedsDisplay(bounds)
        }

        // Detect Shift key release: commit multi-selection
        if !shiftNow && !selectedTerminals.isEmpty {
            let selected = manager.terminals.filter { selectedTerminals.contains($0.id) }
            selectedTerminals.removeAll()
            if selected.count >= 2 {
                onMultiSelect?(selected)
            } else if let single = selected.first {
                onSelectTerminal?(single)
            }
        }
        super.flagsChanged(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // Forward scroll events to the companion NSScrollView for native scrollbar behavior
        beginOverviewScrollInteraction()
        companionScrollView?.scrollWheel(with: event)
        setNeedsDisplay(bounds)
    }

    private func syncScrollOffsetFromCompanionScrollView() {
        guard let scrollView = companionScrollView else { return }
        scrollOffset = scrollView.contentView.bounds.origin.y
    }

    /// Update document view height to match total content.
    private func syncCompanionDocumentView() {
        guard let scrollView = companionScrollView else { return }
        if let documentView = scrollView.documentView {
            let targetHeight = max(totalContentHeight, scrollView.contentView.bounds.height)
            if abs(documentView.frame.height - targetHeight) > 1 {
                documentView.frame.size.height = targetHeight
            }
            if abs(documentView.frame.width - scrollView.contentView.bounds.width) > 1 {
                documentView.frame.size.width = scrollView.contentView.bounds.width
            }
        }
    }

    private func prepareLayoutForInteractionIfNeeded() {
        syncScrollOffsetFromCompanionScrollView()
        updateLayoutCacheIfNeeded()
        syncCompanionDocumentView()
    }

    override func mouseDragged(with event: NSEvent) {
        prepareLayoutForInteractionIfNeeded()
        guard let origin = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) > 6 else { return }

        // Workspace header drag
        if let workspace = mouseDownWorkspace {
            let item = NSPasteboardItem()
            item.setString(workspace, forType: Self.workspacePasteboardType)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let image = NSImage(size: NSSize(width: 160, height: 24))
            image.lockFocus()
            NSColor(calibratedWhite: 0.12, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 160, height: 24), xRadius: 6, yRadius: 6).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor(calibratedWhite: 0.9, alpha: 1),
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
            ]
            NSString(string: workspace).draw(in: NSRect(x: 8, y: 4, width: 144, height: 16), withAttributes: attrs)
            image.unlockFocus()
            draggingItem.setDraggingFrame(NSRect(origin: point, size: image.size), contents: image)
            beginDraggingSession(with: [draggingItem], event: event, source: self)
            mouseDownWorkspace = nil
            return
        }

        // Terminal drag
        guard let controller = mouseDownTerminal else { return }
        let item = NSPasteboardItem()
        item.setString(controller.id.uuidString, forType: .string)
        item.setString(controller.id.uuidString, forType: Self.terminalPasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: NSSize(width: 140, height: 24))
        image.lockFocus()
        NSColor(calibratedWhite: 0.18, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 140, height: 24), xRadius: 6, yRadius: 6).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ]
        NSString(string: controller.title).draw(in: NSRect(x: 8, y: 4, width: 124, height: 16), withAttributes: attrs)
        image.unlockFocus()
        draggingItem.setDraggingFrame(NSRect(origin: point, size: image.size), contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
        mouseDownTerminal = nil
    }

    override func mouseMoved(with event: NSEvent) {
        prepareLayoutForInteractionIfNeeded()
        if isOverviewScrolling { return }
        let point = convert(event.locationInWindow, from: nil)
        let newHoveredIndex = thumbnailOrTitleIndex(at: point)
        let newHoveredCloseID = closeButtonController(at: point)?.id
        let newHoveredWorkspaceClose = workspaceRemoveTarget(at: point)
        let hoverChanged = hoveredIndex != newHoveredIndex ||
            hoveredCloseID != newHoveredCloseID ||
            hoveredWorkspaceClose != newHoveredWorkspaceClose
        hoveredIndex = newHoveredIndex
        hoveredCloseID = newHoveredCloseID
        hoveredWorkspaceClose = newHoveredWorkspaceClose
        updateTooltip(at: point)
        if hoverChanged {
            setNeedsDisplay(bounds)
        }
    }

    override func mouseExited(with event: NSEvent) {
        let hadHover = hoveredIndex != nil || hoveredCloseID != nil || hoveredWorkspaceClose != nil
        hoveredIndex = nil
        hoveredCloseID = nil
        hoveredWorkspaceClose = nil
        hideTooltip()
        if hadHover {
            setNeedsDisplay(bounds)
        }
    }

    private func updateTooltip(at point: NSPoint) {
        let text: String?
        if closeButtonController(at: point) != nil {
            text = "Close Terminal"
        } else if workspaceRemoveTarget(at: point) != nil {
            text = "Delete Workspace"
        } else if workspaceAddTarget(at: point) != nil {
            text = "Add Terminal"
        } else if addWorkspaceButtonFrame.contains(point) {
            text = "Add Workspace"
        } else if let workspace = workspaceHeaderTarget(at: point),
                  workspaceAddTarget(at: point) == nil,
                  workspaceRemoveTarget(at: point) == nil {
            text = "Double-click to rename \"\(workspace)\""
        } else if let controller = terminalTitleTarget(at: point) {
            text = "Double-click to rename \"\(controller.title)\""
        } else {
            text = nil
        }

        if text == currentTooltipText { return }
        currentTooltipText = text

        guard let text else {
            hideTooltip()
            return
        }
        showTooltip(text, at: point)
    }

    private func showTooltip(_ text: String, at point: NSPoint) {
        guard let window else { hideTooltip(); return }

        let label: NSTextField
        let tipWindow: NSWindow
        if let existing = tooltipWindow, let existingLabel = tooltipLabel {
            tipWindow = existing
            label = existingLabel
        } else {
            label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = NSColor.white
            label.isBezeled = false
            label.isEditable = false
            label.drawsBackground = false

            let container = NSView()
            container.wantsLayer = true
            container.addSubview(label)

            tipWindow = NSWindow(
                contentRect: .zero,
                styleMask: [.borderless],
                backing: .buffered,
                defer: true
            )
            tipWindow.isOpaque = false
            tipWindow.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 0.95)
            tipWindow.level = .floating
            tipWindow.hasShadow = true
            tipWindow.contentView = container
            tooltipWindow = tipWindow
            tooltipLabel = label
        }

        label.stringValue = text
        label.sizeToFit()
        let paddingH: CGFloat = 10
        let paddingV: CGFloat = 6
        let labelSize = label.frame.size
        let winSize = NSSize(width: labelSize.width + paddingH * 2, height: labelSize.height + paddingV * 2)
        label.frame = NSRect(x: paddingH, y: paddingV, width: labelSize.width, height: labelSize.height)
        tipWindow.contentView?.frame = NSRect(origin: .zero, size: winSize)

        let screenPoint = window.convertPoint(toScreen: convert(point, to: nil))
        var origin = NSPoint(x: screenPoint.x + 12, y: screenPoint.y + 16)

        // Keep within screen bounds
        if let screen = window.screen ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            if origin.x + winSize.width > visibleFrame.maxX {
                origin.x = visibleFrame.maxX - winSize.width
            }
            if origin.y + winSize.height > visibleFrame.maxY {
                origin.y = screenPoint.y - winSize.height - 4
            }
            if origin.x < visibleFrame.minX {
                origin.x = visibleFrame.minX
            }
            if origin.y < visibleFrame.minY {
                origin.y = visibleFrame.minY
            }
        }

        tipWindow.setFrame(NSRect(origin: origin, size: winSize), display: true)
        tipWindow.orderFront(nil)
    }

    private func hideTooltip() {
        tooltipWindow?.orderOut(nil)
        tooltipLabel = nil
        tooltipWindow = nil
        currentTooltipText = nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if pb.string(forType: Self.workspacePasteboardType) != nil || pb.string(forType: .string) != nil {
            return .move
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        let point = convert(sender.draggingLocation, from: nil)

        // Auto-scroll when dragging near top/bottom edges
        startDragAutoScroll(at: point)

        if pb.string(forType: Self.workspacePasteboardType) != nil {
            // Workspace drag: show indicator between workspace sections
            dragInsertionIndicator = nil
            dragWorkspaceIndicator = computeWorkspaceDropIndicator(at: point)
            updateRenderLoopState()
            setNeedsDisplay(bounds)
            return .move
        }

        if pb.string(forType: .string) != nil {
            // Terminal drag: show indicator at insertion position
            dragWorkspaceIndicator = nil
            dragInsertionIndicator = computeTerminalDropIndicator(at: point)
            updateRenderLoopState()
            setNeedsDisplay(bounds)

            // Accept drop on workspace header or terminal grid
            if workspaceHeaderTarget(at: point) != nil || dragInsertionIndicator != nil {
                return .move
            }
            // Also accept if over any workspace content area
            for layout in cachedWorkspaceLayouts {
                if layout.frame.contains(point) { return .move }
            }
        }
        dragInsertionIndicator = nil
        dragWorkspaceIndicator = nil
        updateRenderLoopState()
        setNeedsDisplay(bounds)
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragInsertionIndicator = nil
        dragWorkspaceIndicator = nil
        stopDragAutoScroll()
        setNeedsDisplay(bounds)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let point = convert(sender.draggingLocation, from: nil)
        dragInsertionIndicator = nil
        dragWorkspaceIndicator = nil
        stopDragAutoScroll()

        // Workspace reorder
        if let workspaceName = pb.string(forType: Self.workspacePasteboardType) {
            if let targetIndex = computeWorkspaceDropIndex(at: point) {
                onReorderWorkspace?(workspaceName, targetIndex)
                return true
            }
            return false
        }

        // Terminal drag
        guard let idString = pb.string(forType: .string),
              let id = UUID(uuidString: idString),
              let controller = manager.terminals.first(where: { $0.id == id }) else {
            return false
        }

        // Drop on workspace header: move to that workspace
        if let workspace = workspaceHeaderTarget(at: point) {
            onMoveTerminalToWorkspace?(controller, workspace)
            return true
        }

        // Drop on terminal grid: reorder
        if let (workspace, index) = computeTerminalDropPosition(at: point) {
            onReorderTerminal?(controller, workspace, index)
            return true
        }

        return false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    // MARK: - Drag Auto-Scroll

    private func startDragAutoScroll(at point: NSPoint) {
        let edge = Self.dragAutoScrollEdge
        let maxScroll = max(0, totalContentHeight - bounds.height)
        guard maxScroll > 0 else {
            stopDragAutoScroll()
            return
        }

        let scrollDelta: CGFloat
        if point.y < edge {
            // Near top edge: scroll up (negative offset)
            let proximity = 1.0 - (point.y / edge)
            scrollDelta = -Self.dragAutoScrollSpeed * proximity
        } else if point.y > bounds.height - edge {
            // Near bottom edge: scroll down (positive offset)
            let proximity = 1.0 - ((bounds.height - point.y) / edge)
            scrollDelta = Self.dragAutoScrollSpeed * proximity
        } else {
            stopDragAutoScroll()
            return
        }

        // Start or continue timer
        if dragAutoScrollTimer == nil {
            dragAutoScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.performDragAutoScroll()
            }
            updateRenderLoopState()
        }
        // Store the delta for the timer callback
        dragAutoScrollDelta = scrollDelta
    }

    private var dragAutoScrollDelta: CGFloat = 0

    private func performDragAutoScroll() {
        guard let scrollView = companionScrollView else { return }
        let maxScroll = max(0, totalContentHeight - bounds.height)
        guard maxScroll > 0 else { return }

        var clipBounds = scrollView.contentView.bounds
        clipBounds.origin.y = min(max(clipBounds.origin.y + dragAutoScrollDelta, 0), maxScroll)
        scrollView.contentView.setBoundsOrigin(clipBounds.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func stopDragAutoScroll() {
        dragAutoScrollTimer?.invalidate()
        dragAutoScrollTimer = nil
        dragAutoScrollDelta = 0
        updateRenderLoopState()
    }

    // MARK: - Drop Position Calculation

    private func computeTerminalDropPosition(at point: NSPoint) -> (workspace: String, index: Int)? {
        for layout in cachedWorkspaceLayouts {
            guard layout.frame.contains(point) else { continue }

            if layout.terminals.isEmpty {
                return (layout.name, 0)
            }

            // Find closest insertion point
            for (i, thumb) in layout.terminals.enumerated() {
                let fullFrame = thumb.title.union(thumb.thumbnail)
                if point.x < fullFrame.midX && point.y < fullFrame.maxY && point.y >= fullFrame.minY {
                    return (layout.name, i)
                }
                // Check if we're at the end of a row
                let isLastInRow = (i + 1 >= layout.terminals.count) ||
                    layout.terminals[i + 1].title.origin.y > thumb.title.origin.y + 1
                if isLastInRow && point.y >= fullFrame.minY && point.y < fullFrame.maxY && point.x >= fullFrame.midX {
                    return (layout.name, i + 1)
                }
            }

            // Below all terminals
            return (layout.name, layout.terminals.count)
        }
        return nil
    }

    private func computeTerminalDropIndicator(at point: NSPoint) -> NSRect? {
        guard let (workspace, index) = computeTerminalDropPosition(at: point) else { return nil }
        guard let wsLayout = cachedWorkspaceLayouts.first(where: { $0.name == workspace }) else { return nil }

        let lineWidth: CGFloat = 3
        if wsLayout.terminals.isEmpty {
            // Show indicator at start of content area
            let contentY = wsLayout.headerFrame.maxY + Layout.thumbnailPadding / 2
            return NSRect(x: wsLayout.frame.minX + Layout.thumbnailPadding,
                          y: contentY, width: lineWidth, height: 60)
        }

        if index < wsLayout.terminals.count {
            let thumb = wsLayout.terminals[index]
            let fullFrame = thumb.title.union(thumb.thumbnail)
            return NSRect(x: fullFrame.minX - lineWidth / 2 - 2, y: fullFrame.minY,
                          width: lineWidth, height: fullFrame.height)
        } else {
            let thumb = wsLayout.terminals[wsLayout.terminals.count - 1]
            let fullFrame = thumb.title.union(thumb.thumbnail)
            return NSRect(x: fullFrame.maxX + 2, y: fullFrame.minY,
                          width: lineWidth, height: fullFrame.height)
        }
    }

    private func computeWorkspaceDropIndex(at point: NSPoint) -> Int? {
        let layouts = cachedWorkspaceLayouts
        guard !layouts.isEmpty else { return nil }

        for (i, layout) in layouts.enumerated() {
            if point.y < layout.frame.midY {
                return i
            }
        }
        return layouts.count
    }

    private func computeWorkspaceDropIndicator(at point: NSPoint) -> NSRect? {
        let layouts = cachedWorkspaceLayouts
        guard !layouts.isEmpty else { return nil }

        let lineHeight: CGFloat = 3
        let outerPad = Layout.workspacePadding
        let availableWidth = bounds.width - outerPad * 2

        for layout in layouts {
            if point.y < layout.frame.midY {
                let y = layout.frame.minY - outerPad / 2
                return NSRect(x: outerPad, y: y - lineHeight / 2, width: availableWidth, height: lineHeight)
            }
        }
        // After last workspace
        let lastFrame = layouts[layouts.count - 1].frame
        let y = lastFrame.maxY + outerPad / 2
        return NSRect(x: outerPad, y: y - lineHeight / 2, width: availableWidth, height: lineHeight)
    }

    private func promptRenameWorkspace(_ workspace: String) {
        let alert = NSAlert.pterm()
        alert.messageText = "Rename Workspace"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = workspace
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != workspace else { return }
        onRenameWorkspace?(workspace, newName)
    }

    private func promptRenameTerminalTitle(_ controller: TerminalController) {
        let alert = NSAlert.pterm()
        alert.messageText = "Rename Terminal"
        alert.informativeText = "Leave empty to use the current directory name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = controller.customTitle ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onRenameTerminalTitle?(controller, value.isEmpty ? nil : value)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Cmd+T: new terminal (handled by menu, but also catch here)
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+A: select all terminals and enter split view
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "a" {
            selectAllTerminals()
            return true
        }

        for action in ShortcutAction.allCases {
            guard shortcutConfiguration.matches(action, event: event),
                  let selector = action.appDelegateSelector else {
                continue
            }
            return NSApp.sendAction(selector, to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - MTKViewDelegate

extension IntegratedView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Nothing to do — layout is computed each frame
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            return
        }

        renderOverviewScene(
            renderPassDescriptor: renderPassDescriptor,
            commandBuffer: commandBuffer,
            drawableSize: view.drawableSize
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()
        trimStagingVertexStorageAfterDraw()
        scheduleIdleBufferRelease()
    }

    private func renderOverviewScene(
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        drawableSize: CGSize
    ) {
        let sf = Float(renderer.glyphAtlas.scaleFactor)
        let time = Float(CACurrentMediaTime())
        syncScrollOffsetFromCompanionScrollView()
        updateLayoutCacheIfNeeded()
        syncCompanionDocumentView()
        invalidateTextVertexCacheIfNeeded()

        renderPassDescriptor.colorAttachments[0].clearColor = Self.overviewBackgroundClearColor()

        let viewportSize = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        stagingPreContentOverlayVertices.removeAll(keepingCapacity: true)
        stagingPostContentOverlayVertices.removeAll(keepingCapacity: true)
        stagingThumbnailBgVertices.removeAll(keepingCapacity: true)
        stagingThumbnailGlyphVertices.removeAll(keepingCapacity: true)
        stagingAtlasGlyphVertices.removeAll(keepingCapacity: true)
        stagingIconVertices.removeAll(keepingCapacity: true)
        stagingCircleVertices.removeAll(keepingCapacity: true)
        var currentOverviewFontName = renderer.glyphAtlas.fontName
        var currentOverviewFontSize = renderer.glyphAtlas.fontSize
        stagingPreContentOverlayVertices.reserveCapacity(max(256, cachedVisibleWorkspaceLayouts.count * 120 + cachedVisibleThumbnails.count * 120))
        stagingPostContentOverlayVertices.reserveCapacity(max(256, cachedVisibleWorkspaceLayouts.count * 96 + cachedVisibleThumbnails.count * 96))
        stagingAtlasGlyphVertices.reserveCapacity(max(256, cachedVisibleWorkspaceLayouts.count * 384 + cachedVisibleThumbnails.count * 512))
        stagingIconVertices.reserveCapacity(max(128, cachedVisibleThumbnails.count * 72))
        stagingCircleVertices.reserveCapacity(max(128, cachedVisibleThumbnails.count * 72))
        var thumbnailSurfacesForFrame: [UUID: CachedThumbnailSurface] = [:]
        thumbnailSurfacesForFrame.reserveCapacity(cachedVisibleThumbnails.count)

        for frame in cachedVisibleThumbnails {
            let controller = frame.controller
            let fontSettings = controller.persistedFontSettings
            if currentOverviewFontName != fontSettings.name ||
                abs(Double(currentOverviewFontSize) - fontSettings.size) > 0.001 {
                renderer.updateFont(name: fontSettings.name, size: CGFloat(fontSettings.size))
                currentOverviewFontName = renderer.glyphAtlas.fontName
                currentOverviewFontSize = renderer.glyphAtlas.fontSize
                invalidateTextVertexCacheIfNeeded()
            }
            if let surface = thumbnailSurface(
                for: controller,
                thumbnailSize: frame.thumbnail.size,
                scaleFactor: sf,
                commandBuffer: commandBuffer
            ) {
                thumbnailSurfacesForFrame[controller.id] = surface
            }
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor) else {
            return
        }

        // Render workspace backgrounds (even when empty)
        for workspace in cachedVisibleWorkspaceLayouts {
            drawWorkspaceBackground(
                workspace: workspace,
                scaleFactor: sf,
                viewportSize: viewportSize,
                overlayVertices: &stagingPreContentOverlayVertices,
                glyphVertices: &stagingAtlasGlyphVertices,
                circleVertices: &stagingCircleVertices,
                iconVertices: &stagingIconVertices
            )
        }

        // Render terminal thumbnails
        for frame in cachedVisibleThumbnails {
            let controller = frame.controller
            let fontSettings = controller.persistedFontSettings
            if currentOverviewFontName != fontSettings.name ||
                abs(Double(currentOverviewFontSize) - fontSettings.size) > 0.001 {
                flushOverviewContentBatch(
                    encoder: encoder,
                    viewportSize: viewportSize,
                    preContentOverlayVertices: &stagingPreContentOverlayVertices,
                    atlasGlyphVertices: &stagingAtlasGlyphVertices
                )
                renderer.updateFont(name: fontSettings.name, size: CGFloat(fontSettings.size))
                currentOverviewFontName = renderer.glyphAtlas.fontName
                currentOverviewFontSize = renderer.glyphAtlas.fontSize
                invalidateTextVertexCacheIfNeeded()
            }

            // Draw thumbnail border/background
            let isHovered = hoveredIndex.flatMap { index in
                guard index < cachedFlattenedThumbnails.count else { return false }
                return cachedFlattenedThumbnails[index].controller.id == controller.id
            } ?? false
            let isSelected = selectedTerminals.contains(controller.id)
            let isActiveOutput = activeOutputTerminals.contains(controller.id)
            drawThumbnailBackground(
                frame: frame.thumbnail,
                titleFrame: frame.title,
                isHovered: isHovered,
                isSelected: isSelected,
                isActiveOutput: isActiveOutput,
                time: time,
                scaleFactor: sf,
                viewportSize: viewportSize,
                vertices: &stagingPreContentOverlayVertices
            )

            if let cachedThumbnailSurface = thumbnailSurfacesForFrame[controller.id]
                ?? thumbnailSurface(
                    for: controller,
                    thumbnailSize: frame.thumbnail.size,
                    scaleFactor: sf,
                    commandBuffer: nil
                ) {
                drawThumbnailSurface(
                    frame: frame.thumbnail,
                    texture: cachedThumbnailSurface.texture,
                    scaleFactor: sf,
                    encoder: encoder,
                    viewportSize: viewportSize
                )
            }

            // Draw title text
            drawTitle(
                controllerID: controller.id,
                title: controller.title,
                pid: controller.foregroundProcessID ?? controller.processID,
                shellPID: controller.processID,
                frame: frame.title,
                scaleFactor: sf,
                viewportSize: viewportSize,
                glyphVertices: &stagingAtlasGlyphVertices
            )

            // Draw close button
            let isCloseHovered = hoveredCloseID == controller.id
            drawCloseButton(
                frame: frame.close,
                isHovered: isCloseHovered,
                scaleFactor: sf,
                viewportSize: viewportSize,
                circleVertices: &stagingCircleVertices,
                iconVertices: &stagingIconVertices
            )
        }

        flushOverviewContentBatch(
            encoder: encoder,
            viewportSize: viewportSize,
            preContentOverlayVertices: &stagingPreContentOverlayVertices,
            atlasGlyphVertices: &stagingAtlasGlyphVertices
        )

        // Draw "Select All" / "Deselect" buttons (on top of thumbnails, only when Shift is held)
        if isShiftDown {
            for workspace in cachedVisibleWorkspaceLayouts where !workspace.terminals.isEmpty {
                drawTextButton(
                    text: "Select All",
                    frame: workspace.selectAllFrame,
                    scaleFactor: sf,
                    viewportSize: viewportSize,
                    bgColor: (0.15, 0.30, 0.55, 0.9),
                    fgColor: (0.9, 0.9, 0.9, 1.0),
                    overlayVertices: &stagingPostContentOverlayVertices,
                    glyphVertices: &stagingAtlasGlyphVertices
                )
                let hasSelection = workspace.terminals.contains { selectedTerminals.contains($0.controller.id) }
                if hasSelection {
                    drawTextButton(
                        text: "Deselect",
                        frame: workspace.deselectFrame,
                        scaleFactor: sf,
                        viewportSize: viewportSize,
                        bgColor: (0.35, 0.20, 0.15, 0.9),
                        fgColor: (0.9, 0.9, 0.9, 1.0),
                        overlayVertices: &stagingPostContentOverlayVertices,
                        glyphVertices: &stagingAtlasGlyphVertices
                    )
                }
            }
        }

        // Draw "+" button for adding new workspace
        drawAddWorkspaceButton(
            scaleFactor: sf,
            viewportSize: viewportSize,
            vertices: &stagingPostContentOverlayVertices
        )

        // Draw drag drop indicators
        drawDropIndicators(
            scaleFactor: sf,
            viewportSize: viewportSize,
            vertices: &stagingPostContentOverlayVertices
        )

        drawVertices(
            stagingPostContentOverlayVertices,
            encoder: encoder,
            pipeline: renderer.overlayPipeline,
            viewportSize: viewportSize,
            bufferSlot: .overviewPostOverlay
        )
        drawGlyphVertices(
            stagingAtlasGlyphVertices,
            encoder: encoder,
            texture: renderer.glyphAtlas.texture,
            viewportSize: viewportSize,
            bufferSlot: .overviewTextGlyph
        )
        drawCircleVertices(
            stagingCircleVertices,
            encoder: encoder,
            viewportSize: viewportSize,
            bufferSlot: .overviewCircleGlyph
        )
        drawGlyphVertices(
            stagingIconVertices,
            encoder: encoder,
            texture: ensureCloseIconTexture(),
            viewportSize: viewportSize,
            bufferSlot: .overviewIconGlyph,
            samplerState: renderer.thumbnailSamplerState
        )

        encoder.endEncoding()
    }

    private func flushOverviewContentBatch(
        encoder: MTLRenderCommandEncoder,
        viewportSize: SIMD2<Float>,
        preContentOverlayVertices: inout [Float],
        atlasGlyphVertices: inout [Float]
    ) {
        drawVertices(
            preContentOverlayVertices,
            encoder: encoder,
            pipeline: renderer.overlayPipeline,
            viewportSize: viewportSize,
            bufferSlot: .overviewPreOverlay
        )
        drawGlyphVertices(
            atlasGlyphVertices,
            encoder: encoder,
            texture: renderer.glyphAtlas.texture,
            viewportSize: viewportSize,
            bufferSlot: .overviewTextGlyph
        )
        preContentOverlayVertices.removeAll(keepingCapacity: true)
        atlasGlyphVertices.removeAll(keepingCapacity: true)
    }

    private func updateRenderLoopState() {
        let isDragging = dragAutoScrollTimer != nil || dragInsertionIndicator != nil || dragWorkspaceIndicator != nil
        let shouldAnimate = isDragging
        preferredFramesPerSecond = isDragging ? 30 : 12
        isPaused = !shouldAnimate
        enableSetNeedsDisplay = !shouldAnimate
        updateOutputPulseTimer(isDragging: isDragging)
        if !shouldAnimate {
            setNeedsDisplay(bounds)
        }
    }

    private func updateOutputPulseTimer(isDragging: Bool) {
        if isDragging || isOverviewScrolling || activeOutputTerminals.isEmpty {
            outputPulseTimer?.invalidate()
            outputPulseTimer = nil
            return
        }
        guard outputPulseTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.requestOverviewOutputDisplay()
        }
        RunLoop.main.add(timer, forMode: .common)
        outputPulseTimer = timer
    }

    private func requestOverviewOutputDisplay() {
        ensureDrawableStorageAllocatedIfNeeded()
        overviewOutputDisplayRequestCount += 1
        setNeedsDisplay(bounds)
    }

    private func scheduleOverviewContentRedraw(forceImmediate: Bool = false) {
        let now = CACurrentMediaTime()
        let visibleTerminalCount = cachedVisibleThumbnails.isEmpty ? manager.terminals.count : cachedVisibleThumbnails.count
        let minimumInterval = Self.effectiveOutputContentRedrawInterval(visibleTerminalCount: visibleTerminalCount)
        if forceImmediate || now - lastOutputContentRedrawTime >= minimumInterval {
            outputContentRedrawTimer?.invalidate()
            outputContentRedrawTimer = nil
            lastOutputContentRedrawTime = now
            requestOverviewOutputDisplay()
            return
        }
        guard outputContentRedrawTimer == nil else { return }
        let remaining = minimumInterval - (now - lastOutputContentRedrawTime)
        let timer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.outputContentRedrawTimer?.invalidate()
            self.outputContentRedrawTimer = nil
            self.lastOutputContentRedrawTime = CACurrentMediaTime()
            self.requestOverviewOutputDisplay()
        }
        RunLoop.main.add(timer, forMode: .common)
        outputContentRedrawTimer = timer
    }

    private func updateCompanionScrollObservation(oldValue: NSScrollView?, newValue: NSScrollView?) {
        if let companionScrollObserver {
            NotificationCenter.default.removeObserver(companionScrollObserver)
            self.companionScrollObserver = nil
        }
        oldValue?.contentView.postsBoundsChangedNotifications = false
        guard let newValue else { return }
        newValue.contentView.postsBoundsChangedNotifications = true
        companionScrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: newValue.contentView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.beginOverviewScrollInteraction()
            self.syncScrollOffsetFromCompanionScrollView()
            self.setNeedsDisplay(self.bounds)
        }
    }

    // MARK: - Drawing Helpers

    private func drawThumbnailBackground(
        frame: NSRect,
        titleFrame: NSRect,
        isHovered: Bool,
        isSelected: Bool,
        isActiveOutput: Bool,
        time: Float,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        vertices: inout [Float]
    ) {
        let fullFrame = titleFrame.union(frame)
        let x = Float(fullFrame.origin.x) * scaleFactor
        let y = Float(fullFrame.origin.y) * scaleFactor
        let w = Float(fullFrame.width) * scaleFactor
        let h = Float(fullFrame.height) * scaleFactor

        // Title bar background (dark gray)
        let titleX = Float(titleFrame.origin.x) * scaleFactor
        let titleY = Float(titleFrame.origin.y) * scaleFactor
        let titleW = Float(titleFrame.width) * scaleFactor
        let titleH = Float(titleFrame.height) * scaleFactor
        let appearance = renderer.terminalAppearance
        renderer.addQuadPublic(
            to: &vertices, x: titleX, y: titleY, w: titleW, h: titleH,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: Self.uiThumbnailTitleBarColor(alpha: 1.0),
            bg: (0, 0, 0, 0)
        )

        // Terminal content background (solid black)
        let contentX = Float(frame.origin.x) * scaleFactor
        let contentY = Float(frame.origin.y) * scaleFactor
        let contentW = Float(frame.width) * scaleFactor
        let contentH = Float(frame.height) * scaleFactor
        renderer.addQuadPublic(
            to: &vertices, x: contentX, y: contentY, w: contentW, h: contentH,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (
                appearance.defaultBackground.r,
                appearance.defaultBackground.g,
                appearance.defaultBackground.b,
                appearance.defaultBackground.a
            ),
            bg: (0, 0, 0, 0)
        )

        // Border
        let borderAlpha: Float
        let borderColor: (Float, Float, Float)
        let borderWidth: Float
        if isActiveOutput {
            // Gentle red pulse: fades between 0.15 and 0.8
            let pulse = 0.475 + 0.325 * sin(time * 3.0)
            borderAlpha = pulse
            let activeBorder = Self.uiActiveOutputBorderColor()
            borderColor = (activeBorder.r, activeBorder.g, activeBorder.b)
            borderWidth = Float(Layout.borderWidth)
        } else if isSelected {
            borderAlpha = 1.0
            let selectedBorder = Self.uiSelectionBorderColor()
            borderColor = (selectedBorder.r, selectedBorder.g, selectedBorder.b)
            borderWidth = Float(Layout.selectedBorderWidth)
        } else if isHovered {
            borderAlpha = 0.6
            let hoverBorder = Self.uiNeutralBorderColor()
            borderColor = (hoverBorder.r, hoverBorder.g, hoverBorder.b)
            borderWidth = Float(Layout.borderWidth)
        } else {
            borderAlpha = 0.3
            let defaultBorder = Self.uiNeutralBorderColor()
            borderColor = (defaultBorder.r, defaultBorder.g, defaultBorder.b)
            borderWidth = Float(Layout.borderWidth)
        }
        let bw: Float = borderWidth * scaleFactor

        // Selection overlay tint (subtle blue highlight on content area)
        if isSelected {
            renderer.addQuadPublic(
                to: &vertices, x: contentX, y: contentY, w: contentW, h: contentH,
                tx: 0, ty: 0, tw: 0, th: 0,
                fg: Self.uiSelectionTintColor(alpha: 0.15),
                bg: (0, 0, 0, 0)
            )
        }
        // Top
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: w, h: bw,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (borderColor.0, borderColor.1, borderColor.2, borderAlpha),
                               bg: (0, 0, 0, 0))
        // Bottom
        renderer.addQuadPublic(to: &vertices, x: x, y: y + h - bw, w: w, h: bw,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (borderColor.0, borderColor.1, borderColor.2, borderAlpha),
                               bg: (0, 0, 0, 0))
        // Left
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: bw, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (borderColor.0, borderColor.1, borderColor.2, borderAlpha),
                               bg: (0, 0, 0, 0))
        // Right
        renderer.addQuadPublic(to: &vertices, x: x + w - bw, y: y, w: bw, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (borderColor.0, borderColor.1, borderColor.2, borderAlpha),
                               bg: (0, 0, 0, 0))
    }

    private func drawWorkspaceBackground(
        workspace: WorkspaceLayout,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        overlayVertices: inout [Float],
        glyphVertices: inout [Float],
        circleVertices: inout [Float],
        iconVertices: inout [Float]
    ) {
        let x = Float(workspace.frame.origin.x) * scaleFactor
        let y = Float(workspace.frame.origin.y) * scaleFactor
        let w = Float(workspace.frame.width) * scaleFactor
        let h = Float(workspace.frame.height) * scaleFactor
        let bw = Float(Layout.workspaceBorderWidth) * scaleFactor
        renderer.addQuadPublic(to: &overlayVertices, x: x, y: y, w: w, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: Self.uiWorkspaceBackgroundColor(alpha: 0.65), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &overlayVertices, x: x, y: y, w: w, h: bw,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: Self.uiWorkspaceBorderColor(alpha: 0.7), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &overlayVertices, x: x, y: y + h - bw, w: w, h: bw,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: Self.uiWorkspaceBorderColor(alpha: 0.7), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &overlayVertices, x: x, y: y, w: bw, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: Self.uiWorkspaceBorderColor(alpha: 0.7), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &overlayVertices, x: x + w - bw, y: y, w: bw, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: Self.uiWorkspaceBorderColor(alpha: 0.7), bg: (0, 0, 0, 0))

        drawWorkspaceHeaderText(
            text: workspace.name,
            frame: workspace.headerFrame,
            scaleFactor: scaleFactor,
            viewportSize: viewportSize,
            glyphVertices: &glyphVertices
        )
        drawWorkspaceAddButton(
            frame: workspace.addFrame,
            scaleFactor: scaleFactor,
            viewportSize: viewportSize,
            vertices: &overlayVertices
        )
        drawWorkspaceCloseButton(
            frame: workspace.closeFrame,
            isHovered: hoveredWorkspaceClose == workspace.name,
            scaleFactor: scaleFactor,
            viewportSize: viewportSize,
            circleVertices: &circleVertices,
            iconVertices: &iconVertices
        )
    }

    private func drawWorkspaceHeaderText(
        text: String,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        glyphVertices: inout [Float]
    ) {
        let textX = frame.minX + Layout.closeButtonSize + 8
        let halfGlyph = renderer.glyphAtlas.cellHeight * 0.5
        drawRightAlignedTitleText(
            text: text,
            frame: NSRect(x: textX, y: frame.minY + halfGlyph - 4, width: frame.width - Layout.closeButtonSize - 8, height: frame.height),
            scaleFactor: scaleFactor,
            viewportSize: viewportSize,
            color: Self.uiWorkspaceHeaderTextColor(alpha: 1.0),
            alignment: .left,
            glyphVertices: &glyphVertices
        )
    }

    private func drawTitle(
        controllerID: UUID,
        title: String,
        pid: pid_t,
        shellPID: pid_t,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        glyphVertices: inout [Float]
    ) {
        let maxChars = Int(frame.width / renderer.glyphAtlas.cellWidth) - 2 // Leave room for close button
        let displayTitle = String(title.prefix(max(0, maxChars)))
        appendTextVertices(
            text: displayTitle,
            scaleFactor: scaleFactor,
            glyphScale: 0.85,
            color: Self.uiTitleTextColor(alpha: 1.0),
            originX: Float(frame.origin.x + Layout.closeButtonSize + 8) * scaleFactor,
            originY: Float(frame.origin.y + (Layout.titleBarHeight - renderer.glyphAtlas.cellHeight) / 2) * scaleFactor,
            to: &glyphVertices
        )

        let cpuStatusText: String?
        if isOverviewScrolling {
            let cached = cachedCPUStatusByTerminalID[controllerID]
            cpuStatusText = (cached?.pid == pid && cached?.shellPID == shellPID) ? cached?.text : nil
        } else if let usage = cpuUsageProvider?(pid), usage >= 0 {
            let text = String(format: "CPU: %.1f%%", usage)
            cacheCPUStatus(controllerID: controllerID, pid: pid, shellPID: shellPID, text: text)
            cpuStatusText = text
        } else if pid != shellPID {
            let text = "CPU: N/A"
            cacheCPUStatus(controllerID: controllerID, pid: pid, shellPID: shellPID, text: text)
            cpuStatusText = text
        } else {
            cacheCPUStatus(controllerID: controllerID, pid: pid, shellPID: shellPID, text: nil)
            cpuStatusText = nil
        }

        if let cpuStatusText {
            drawRightAlignedTitleText(
                text: cpuStatusText,
                frame: frame,
                scaleFactor: scaleFactor,
                viewportSize: viewportSize,
                useCache: false,
                glyphVertices: &glyphVertices
            )
        }
    }

    private func drawRightAlignedTitleText(
        text: String,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        color: (Float, Float, Float, Float) = IntegratedView.uiSecondaryTitleTextColor(alpha: 1.0),
        alignment: NSTextAlignment = .right,
        useCache: Bool = true,
        glyphVertices: inout [Float]
    ) {
        let thumbGlyphScale: Float = 0.8
        let cached = textVertices(
            for: text,
            scaleFactor: scaleFactor,
            glyphScale: thumbGlyphScale,
            color: color,
            useCache: useCache
        )
        let startX: Float
        if alignment == .left {
            startX = Float(frame.minX) * scaleFactor
        } else {
            startX = Float(frame.maxX) * scaleFactor - cached.width - 8 * scaleFactor
        }
        let textY = Float(frame.origin.y + (Layout.titleBarHeight - renderer.glyphAtlas.cellHeight) / 2) * scaleFactor
        appendTranslatedVertices(cached.vertices, dx: startX, dy: textY, to: &glyphVertices)
    }

    private func drawWorkspaceAddButton(
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        vertices: inout [Float]
    ) {
        let x = Float(frame.origin.x) * scaleFactor
        let y = Float(frame.origin.y) * scaleFactor
        let size = Float(frame.width) * scaleFactor
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: size, h: size,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: Self.uiWorkspaceAddButtonBackgroundColor(alpha: 0.9), bg: (0, 0, 0, 0))
        let lineW: Float = 2.0 * scaleFactor
        let lineLen: Float = size * 0.5
        let cx = x + size / 2
        let cy = y + size / 2
        renderer.addQuadPublic(to: &vertices, x: cx - lineLen / 2, y: cy - lineW / 2,
                               w: lineLen, h: lineW, tx: 0, ty: 0, tw: 0, th: 0,
                               fg: Self.uiWorkspaceAddButtonForegroundColor(alpha: 1.0), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &vertices, x: cx - lineW / 2, y: cy - lineLen / 2,
                               w: lineW, h: lineLen, tx: 0, ty: 0, tw: 0, th: 0,
                               fg: Self.uiWorkspaceAddButtonForegroundColor(alpha: 1.0), bg: (0, 0, 0, 0))
    }

    private func drawTextButton(
        text: String,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        bgColor: (Float, Float, Float, Float),
        fgColor: (Float, Float, Float, Float),
        overlayVertices: inout [Float],
        glyphVertices: inout [Float]
    ) {
        // Draw background
        let x = Float(frame.origin.x) * scaleFactor
        let y = Float(frame.origin.y) * scaleFactor
        let w = Float(frame.width) * scaleFactor
        let h = Float(frame.height) * scaleFactor
        renderer.addQuadPublic(to: &overlayVertices, x: x, y: y, w: w, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: bgColor, bg: (0, 0, 0, 0))

        // Draw horizontally and vertically centered text
        let thumbGlyphScale: Float = 0.8
        let cached = cachedTextVertices(for: text, scaleFactor: scaleFactor, glyphScale: thumbGlyphScale, color: fgColor)
        let cellH = Float(renderer.glyphAtlas.cellHeight) * scaleFactor * thumbGlyphScale
        let textWidth = cached.width
        let startX = x + (w - textWidth) / 2
        let startY = y + (h - cellH) / 2
        appendTranslatedVertices(cached.vertices, dx: startX, dy: startY, to: &glyphVertices)
    }

    private func drawWorkspaceCloseButton(
        frame: NSRect,
        isHovered: Bool,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        circleVertices: inout [Float],
        iconVertices: inout [Float]
    ) {
        drawMacOSCloseButton(
            frame: frame,
            isHovered: isHovered,
            scaleFactor: scaleFactor,
            circleVertices: &circleVertices,
            iconVertices: &iconVertices
        )
    }

    /// Loads the close icon from the bundled PNG resource and creates an r8Unorm texture.
    /// The white-on-black image is drawn into a grayscale context for single-channel use.
    private func ensureCloseIconTexture() -> MTLTexture? {
        if let existing = closeIconTexture { return existing }

        guard let url = Self.closeIconURL(),
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            fatalError("Missing bundled close_icon.png resource")
        }

        let size = Self.closeIconTextureSize
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Draw the PNG into a grayscale context at the target texture size.
        // The white X on transparent background becomes white-on-black in r8Unorm.
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let data = ctx.data else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = renderer.device.hasUnifiedMemory ? .shared : .managed
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: size
        )
        closeIconTexture = texture
        return texture
    }

    private static func closeIconURL(filePath: StaticString = #filePath) -> URL? {
        if let bundled = Bundle.main.url(forResource: "close_icon", withExtension: "png") {
            return bundled
        }

        let sourceURL = URL(fileURLWithPath: "\(filePath)")
        let projectRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryResource = projectRoot.appendingPathComponent("Resources/close_icon.png")
        if FileManager.default.fileExists(atPath: repositoryResource.path) {
            return repositoryResource
        }

        return nil
    }

    /// Programmatically generates a filled circle texture (r8Unorm).
    /// Uses CoreGraphics to draw a perfect anti-aliased circle with pure white (255) fill,
    /// guaranteeing exact coverage=1.0 inside the circle for correct color tinting.
    private func ensureCloseCircleTexture() -> MTLTexture? {
        if let existing = closeCircleTexture { return existing }

        let size = Self.closeIconTextureSize
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Black background
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // White filled circle
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let data = ctx.data else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = renderer.device.hasUnifiedMemory ? .shared : .managed
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: size
        )
        closeCircleTexture = texture
        return texture
    }

    /// Draws a macOS-style close button: red circle always, white × only on hover.
    private func drawMacOSCloseButton(
        frame: NSRect,
        isHovered: Bool,
        scaleFactor: Float,
        circleVertices: inout [Float],
        iconVertices: inout [Float]
    ) {
        let frameX = Float(frame.origin.x) * scaleFactor
        let frameY = Float(frame.origin.y) * scaleFactor
        let frameSize = Float(frame.width) * scaleFactor
        let inset = max(1.0, round(Float(Self.closeButtonInsetPoints) * scaleFactor))
        let x = round(frameX) + inset
        let y = round(frameY) + inset
        let size = max(1.0, round(frameSize) - inset * 2.0)

        // Red circle — always visible, using the macOS stoplight color interpreted in Display P3
        // and converted into the renderer's sRGB working space.
        let circleAlpha: Float = 1.0
        let circleColor = Self.macOSCloseButtonCircleColor()
        renderer.addQuadPublic(
            to: &circleVertices, x: x, y: y, w: size, h: size,
            tx: 0, ty: 1, tw: 1, th: -1,
            fg: (circleColor.r, circleColor.g, circleColor.b, circleAlpha),
            bg: (0, 0, 0, 0)
        )

        // × icon — only on hover, also converted from Display P3 into sRGB.
        if isHovered {
            let iconColor = Self.macOSCloseButtonIconColor()
            renderer.addQuadPublic(
                to: &iconVertices, x: x, y: y, w: size, h: size,
                tx: 0, ty: 1, tw: 1, th: -1,
                fg: (iconColor.r, iconColor.g, iconColor.b, 1),
                bg: (0, 0, 0, 0)
            )
        }
    }

    static func macOSCloseButtonCircleColor() -> (r: Float, g: Float, b: Float) {
        displayP3Color(red: 236.0 / 255.0, green: 103.0 / 255.0, blue: 101.0 / 255.0)
    }

    static func macOSCloseButtonIconColor() -> (r: Float, g: Float, b: Float) {
        displayP3Color(red: 119.0 / 255.0, green: 52.0 / 255.0, blue: 50.0 / 255.0)
    }

    static func srgbColor(red: CGFloat, green: CGFloat, blue: CGFloat) -> (r: Float, g: Float, b: Float) {
        convertedColorToSRGB(NSColor(srgbRed: red, green: green, blue: blue, alpha: 1.0))
    }

    static func displayP3Color(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> (r: Float, g: Float, b: Float) {
        convertedColorToSRGB(NSColor(displayP3Red: red, green: green, blue: blue, alpha: 1.0))
    }

    private static func convertedColorToSRGB(_ color: NSColor) -> (r: Float, g: Float, b: Float) {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return (
            Float(converted.redComponent),
            Float(converted.greenComponent),
            Float(converted.blueComponent)
        )
    }

    private static func withAlpha(
        _ color: (r: Float, g: Float, b: Float),
        _ alpha: Float
    ) -> (Float, Float, Float, Float) {
        (color.r, color.g, color.b, alpha)
    }

    private static func uiThumbnailTitleBarColor(alpha: Float) -> (Float, Float, Float, Float) {
        withAlpha(srgbColor(red: 0.15, green: 0.15, blue: 0.15), alpha)
    }

    private static func uiActiveOutputBorderColor() -> (r: Float, g: Float, b: Float) {
        srgbColor(red: 0.9, green: 0.2, blue: 0.15)
    }

    private static func uiSelectionBorderColor() -> (r: Float, g: Float, b: Float) {
        srgbColor(red: 0.3, green: 0.6, blue: 1.0)
    }

    private static func uiNeutralBorderColor() -> (r: Float, g: Float, b: Float) {
        srgbColor(red: 0.4, green: 0.4, blue: 0.4)
    }

    private static func uiSelectionTintColor(alpha: Float) -> (Float, Float, Float, Float) {
        withAlpha(srgbColor(red: 0.15, green: 0.3, blue: 0.6), alpha)
    }

    private static func uiWorkspaceBackgroundColor(alpha: Float) -> (Float, Float, Float, Float) {
        withAlpha(srgbColor(red: 0.07, green: 0.07, blue: 0.07), alpha)
    }

    private static func uiWorkspaceBorderColor(alpha: Float) -> (Float, Float, Float, Float) {
        withAlpha(srgbColor(red: 0.28, green: 0.28, blue: 0.28), alpha)
    }

    private static func uiWorkspaceHeaderTextColor(alpha: Float) -> (Float, Float, Float, Float) {
        withAlpha(srgbColor(red: 0.9, green: 0.9, blue: 0.9), alpha)
    }

    private static func uiTitleTextColor(alpha: Float) -> (Float, Float, Float, Float) {
        withAlpha(srgbColor(red: 0.8, green: 0.8, blue: 0.8), alpha)
    }

    private static func uiSecondaryTitleTextColor(alpha: Float) -> (Float, Float, Float, Float) {
        withAlpha(srgbColor(red: 0.55, green: 0.55, blue: 0.55), alpha)
    }

    private static func uiWorkspaceAddButtonBackgroundColor(alpha: Float) -> (Float, Float, Float, Float) {
        withAlpha(srgbColor(red: 0.22, green: 0.22, blue: 0.22), alpha)
    }

    private static func uiWorkspaceAddButtonForegroundColor(alpha: Float) -> (Float, Float, Float, Float) {
        withAlpha(srgbColor(red: 0.85, green: 0.85, blue: 0.85), alpha)
    }

    private static func uiFloatingAddWorkspaceBackgroundColor(alpha: Float) -> (Float, Float, Float, Float) {
        withAlpha(srgbColor(red: 0.20, green: 0.24, blue: 0.20), alpha)
    }

    private static func uiFloatingAddWorkspaceForegroundColor(alpha: Float) -> (Float, Float, Float, Float) {
        withAlpha(srgbColor(red: 0.85, green: 0.92, blue: 0.85), alpha)
    }


    private func drawCloseButton(
        frame: NSRect,
        isHovered: Bool,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        circleVertices: inout [Float],
        iconVertices: inout [Float]
    ) {
        drawMacOSCloseButton(
            frame: frame,
            isHovered: isHovered,
            scaleFactor: scaleFactor,
            circleVertices: &circleVertices,
            iconVertices: &iconVertices
        )
    }

    private func drawAddWorkspaceButton(
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        vertices: inout [Float]
    ) {
        let btnSize = Layout.addButtonSize
        let margin: CGFloat = 20
        // Always fixed at bottom-right of the visible area
        let bx = bounds.width - btnSize - margin
        let by = bounds.height - btnSize - margin

        let x = Float(bx) * scaleFactor
        let y = Float(by) * scaleFactor
        let size = Float(btnSize) * scaleFactor

        // Background
        renderer.addQuadPublic(
            to: &vertices, x: x, y: y, w: size, h: size,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: Self.uiFloatingAddWorkspaceBackgroundColor(alpha: 0.80),
            bg: (0, 0, 0, 0)
        )

        // Plus sign
        let cx = x + size / 2
        let cy = y + size / 2
        let lineW: Float = 2.5 * scaleFactor
        let lineLen: Float = size * 0.4
        renderer.addQuadPublic(
            to: &vertices,
            x: cx - lineLen / 2, y: cy - lineW / 2,
            w: lineLen, h: lineW,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: Self.uiFloatingAddWorkspaceForegroundColor(alpha: 1.0),
            bg: (0, 0, 0, 0)
        )
        renderer.addQuadPublic(
            to: &vertices,
            x: cx - lineW / 2, y: cy - lineLen / 2,
            w: lineW, h: lineLen,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: Self.uiFloatingAddWorkspaceForegroundColor(alpha: 1.0),
            bg: (0, 0, 0, 0)
        )
        addWorkspaceButtonFrame = NSRect(x: bx, y: by, width: btnSize, height: btnSize)
    }

    private func drawVertices(
        _ vertices: [Float],
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState?,
        viewportSize: SIMD2<Float>,
        bufferSlot: MetalRenderer.ViewBufferSlot
    ) {
        guard !vertices.isEmpty, let pipeline else { return }

        encoder.setRenderPipelineState(pipeline)
        if let buf = renderer.reusableBuffer(for: self, slot: bufferSlot, vertices: vertices) {
            var uniforms = MetalRenderer.MetalUniforms(
                viewportSize: viewportSize,
                cursorOpacity: 0,
                time: 0
            )
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalRenderer.MetalUniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: vertices.count / 12)
        }
    }

    private func drawGlyphVertices(
        _ vertices: [Float],
        encoder: MTLRenderCommandEncoder,
        texture: MTLTexture?,
        viewportSize: SIMD2<Float>,
        bufferSlot: MetalRenderer.ViewBufferSlot,
        samplerState: MTLSamplerState? = nil
    ) {
        guard !vertices.isEmpty,
              let pipeline = renderer.glyphPipeline,
              let texture,
              let buf = renderer.reusableBuffer(for: self, slot: bufferSlot, vertices: vertices) else {
            return
        }

        var uniforms = MetalRenderer.MetalUniforms(viewportSize: viewportSize, cursorOpacity: 0, time: 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalRenderer.MetalUniforms>.size, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState ?? renderer.samplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 12)
    }

    private func drawCircleVertices(
        _ vertices: [Float],
        encoder: MTLRenderCommandEncoder,
        viewportSize: SIMD2<Float>,
        bufferSlot: MetalRenderer.ViewBufferSlot
    ) {
        guard !vertices.isEmpty,
              let pipeline = renderer.circlePipeline,
              let buf = renderer.reusableBuffer(for: self, slot: bufferSlot, vertices: vertices) else {
            return
        }

        var uniforms = MetalRenderer.MetalUniforms(viewportSize: viewportSize, cursorOpacity: 0, time: 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalRenderer.MetalUniforms>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 12)
    }

    private func drawThumbnailSurface(
        frame: NSRect,
        texture: MTLTexture,
        scaleFactor: Float,
        encoder: MTLRenderCommandEncoder,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.texturePipeline else { return }
        var vertices: [Float] = []
        vertices.reserveCapacity(72)
        let x = round(Float(frame.origin.x) * scaleFactor)
        let y = round(Float(frame.origin.y) * scaleFactor)
        let w = round(Float(frame.width) * scaleFactor)
        let h = round(Float(frame.height) * scaleFactor)
        renderer.addQuadPublic(
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
        // We draw many thumbnail surfaces in one overview pass. Reusing the same
        // per-view buffer slot here would overwrite vertex data before the GPU
        // consumes earlier draw calls, producing blank or stale thumbnails.
        guard let buf = renderer.makeTemporaryBuffer(vertices: vertices) else {
            return
        }
        var uniforms = MetalRenderer.MetalUniforms(viewportSize: viewportSize, cursorOpacity: 0, time: 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalRenderer.MetalUniforms>.size, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(renderer.samplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 12)
    }

    private func tightlyPackedVertices(_ vertices: [Float]) -> [Float] {
        guard !vertices.isEmpty else { return [] }
        return vertices.withUnsafeBufferPointer { Array($0) }
    }

    private func drawDropIndicators(
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        vertices: inout [Float]
    ) {
        // Terminal insertion indicator (vertical blue line)
        if let rect = dragInsertionIndicator {
            let x = Float(rect.origin.x) * scaleFactor
            let y = Float(rect.origin.y) * scaleFactor
            let w = Float(rect.width) * scaleFactor
            let h = Float(rect.height) * scaleFactor
            renderer.addQuadPublic(to: &vertices, x: x, y: y, w: w, h: h,
                                   tx: 0, ty: 0, tw: 0, th: 0,
                                   fg: (0.3, 0.6, 1.0, 0.9), bg: (0, 0, 0, 0))
        }

        // Workspace reorder indicator (horizontal blue line)
        if let rect = dragWorkspaceIndicator {
            let x = Float(rect.origin.x) * scaleFactor
            let y = Float(rect.origin.y) * scaleFactor
            let w = Float(rect.width) * scaleFactor
            let h = Float(rect.height) * scaleFactor
            renderer.addQuadPublic(to: &vertices, x: x, y: y, w: w, h: h,
                                   tx: 0, ty: 0, tw: 0, th: 0,
                                   fg: (0.3, 0.6, 1.0, 0.9), bg: (0, 0, 0, 0))
        }
    }

    private func cachedTextVertices(
        for text: String,
        scaleFactor: Float,
        glyphScale: Float,
        color: (Float, Float, Float, Float)
    ) -> CachedTextVertices {
        let key = TextVertexCacheKey(
            text: text,
            glyphScaleBits: glyphScale.bitPattern,
            colorBits: (color.0.bitPattern, color.1.bitPattern, color.2.bitPattern, color.3.bitPattern)
        )
        if let cached = textVertexCache[key] {
            return cached
        }

        let cached = makeTextVertices(
            for: text,
            scaleFactor: scaleFactor,
            glyphScale: glyphScale,
            color: color
        )
        textVertexCache[key] = cached
        pruneTextVertexCacheIfNeeded()
        return cached
    }

    private func makeTextVertices(
        for text: String,
        scaleFactor: Float,
        glyphScale: Float,
        color: (Float, Float, Float, Float)
    ) -> CachedTextVertices {

        let chars = Array(text.unicodeScalars)
        let cellW = Float(renderer.glyphAtlas.cellWidth) * scaleFactor * glyphScale
        let cellH = Float(renderer.glyphAtlas.cellHeight) * scaleFactor * glyphScale
        let textY: Float = 0
        var vertices: [Float] = []
        vertices.reserveCapacity(chars.count * 72)

        for (index, scalar) in chars.enumerated() {
            let cp = scalar.value
            guard cp > 0x20,
                  let glyph = renderer.glyphAtlas.glyphInfo(for: cp),
                  glyph.pixelWidth > 0 else {
                continue
            }

            let x = Float(index) * cellW
            let glyphX = x + glyph.cellOffsetX * glyphScale
            let baselineScreenY = textY + cellH - Float(renderer.glyphAtlas.baseline) * scaleFactor * glyphScale
            let glyphY = baselineScreenY - glyph.baselineOffset * glyphScale
            let glyphW = Float(glyph.pixelWidth) * glyphScale
            let glyphH = Float(glyph.pixelHeight) * glyphScale

            renderer.addQuadPublic(
                to: &vertices,
                x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                tx: glyph.textureX, ty: glyph.textureY,
                tw: glyph.textureW, th: glyph.textureH,
                fg: color,
                bg: (0, 0, 0, 0)
            )
        }

        return CachedTextVertices(
            vertices: Array(vertices),
            width: Float(chars.count) * cellW
        )
    }

    private func appendTextVertices(
        text: String,
        scaleFactor: Float,
        glyphScale: Float,
        color: (Float, Float, Float, Float),
        originX: Float,
        originY: Float,
        useCache: Bool = true,
        to target: inout [Float]
    ) {
        let cached = textVertices(
            for: text,
            scaleFactor: scaleFactor,
            glyphScale: glyphScale,
            color: color,
            useCache: useCache
        )
        appendTranslatedVertices(cached.vertices, dx: originX, dy: originY, to: &target)
    }

    private func textVertices(
        for text: String,
        scaleFactor: Float,
        glyphScale: Float,
        color: (Float, Float, Float, Float),
        useCache: Bool
    ) -> CachedTextVertices {
        if useCache {
            return cachedTextVertices(for: text, scaleFactor: scaleFactor, glyphScale: glyphScale, color: color)
        }
        return makeTextVertices(for: text, scaleFactor: scaleFactor, glyphScale: glyphScale, color: color)
    }

    private func appendTranslatedVertices(_ source: [Float], dx: Float, dy: Float, to target: inout [Float]) {
        guard !source.isEmpty else { return }
        target.reserveCapacity(target.count + source.count)
        source.withUnsafeBufferPointer { buffer in
            var index = 0
            while index < buffer.count {
                target.append(buffer[index] + dx)
                target.append(buffer[index + 1] + dy)
                target.append(buffer[index + 2])
                target.append(buffer[index + 3])
                target.append(buffer[index + 4])
                target.append(buffer[index + 5])
                target.append(buffer[index + 6])
                target.append(buffer[index + 7])
                target.append(buffer[index + 8])
                target.append(buffer[index + 9])
                target.append(buffer[index + 10])
                target.append(buffer[index + 11])
                index += 12
            }
        }
    }

}

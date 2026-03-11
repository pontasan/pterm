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

    /// Terminal manager
    private let manager: TerminalManager

    /// Metal renderer
    private let renderer: MetalRenderer

    /// Callback: user clicked a terminal thumbnail (single select).
    var onSelectTerminal: ((TerminalController) -> Void)?

    var onAddWorkspace: (() -> Void)?
    var onAddTerminalToWorkspace: ((String) -> Void)?
    var onRemoveWorkspace: ((String) -> Void)?
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
    }

    /// Callback: user shift-clicked multiple terminals for split view.
    var onMultiSelect: (([TerminalController]) -> Void)?

    /// CPU usage provider for status labels.
    var cpuUsageProvider: ((pid_t) -> Double?)?

    /// Terminals that are actively producing output (border pulses red).
    var activeOutputTerminals: Set<UUID> = []
    var shortcutConfiguration: ShortcutConfiguration = .default
    var explicitWorkspaceNames: [String] = [] {
        didSet { setNeedsDisplay(bounds) }
    }

    /// Cached × icon texture for close buttons (r8Unorm, same as glyph atlas)
    private var closeIconTexture: MTLTexture?
    /// Size in pixels of the cached icon texture
    private static let closeIconTextureSize: Int = 64

    /// Custom tooltip window for instant display
    private var tooltipWindow: NSWindow?
    private var tooltipLabel: NSTextField?
    private var currentTooltipText: String?

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
    weak var companionScrollView: NSScrollView?

    /// Auto-scroll during drag near edges
    private var dragAutoScrollTimer: Timer?
    private static let dragAutoScrollEdge: CGFloat = 60
    private static let dragAutoScrollSpeed: CGFloat = 24

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

    // MARK: - Initialization

    init(frame: NSRect, renderer: MetalRenderer, manager: TerminalManager) {
        self.renderer = renderer
        self.manager = manager

        super.init(frame: frame, device: renderer.device)

        self.delegate = self
        self.preferredFramesPerSecond = 30 // Lower FPS for thumbnails
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.registerForDraggedTypes([.string, Self.terminalPasteboardType, Self.workspacePasteboardType])

        updateTrackingArea()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Multi-Display Support

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

    private func syncScaleFactor() {
        let newScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if newScale != renderer.glyphAtlas.scaleFactor {
            renderer.glyphAtlas.updateScaleFactor(newScale)
        }
        // Ensure drawable matches Retina pixel dimensions
        let expectedSize = CGSize(width: bounds.width * newScale, height: bounds.height * newScale)
        if abs(drawableSize.width - expectedSize.width) > 1 || abs(drawableSize.height - expectedSize.height) > 1 {
            drawableSize = expectedSize
        }
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

    private func workspaceSections() -> [WorkspaceSection] {
        let grouped = Dictionary(grouping: manager.terminals) { controller in
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

        for controller in manager.terminals {
            let trimmed = controller.sessionSnapshot.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "Uncategorized" : trimmed
            if !seen.contains(name) {
                seen.insert(name)
                orderedNames.append(name)
            }
        }

        return orderedNames.map { WorkspaceSection(name: $0, terminals: grouped[$0] ?? []) }
    }

    private func workspaceLayouts() -> [WorkspaceLayout] {
        let sections = workspaceSections()
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
        let thumbHeight = thumbWidth / aspect
        let cellWidth = thumbWidth + innerPad
        let cellHeight = thumbHeight + Layout.titleBarHeight + innerPad

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
        var currentY = outerPad - scrollOffset

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

    /// Return the index of the thumbnail at the given view-coordinates point.
    /// Only matches the thumbnail content area, NOT the title bar.
    private func thumbnailIndex(at point: NSPoint) -> Int? {
        let flattened = cachedWorkspaceLayouts.flatMap(\.terminals)
        for (index, layout) in flattened.enumerated() {
            if layout.thumbnail.contains(point) {
                return index
            }
        }
        return nil
    }

    /// Return the index of the thumbnail whose title OR thumbnail area contains the point.
    /// Used for hover effects and drag initiation (but NOT for navigation).
    private func thumbnailOrTitleIndex(at point: NSPoint) -> Int? {
        let flattened = cachedWorkspaceLayouts.flatMap(\.terminals)
        for (index, layout) in flattened.enumerated() {
            if layout.title.union(layout.thumbnail).contains(point) {
                return index
            }
        }
        return nil
    }

    /// Check if a point hits a close button, returning the associated controller.
    private func closeButtonController(at point: NSPoint) -> TerminalController? {
        let flattened = cachedWorkspaceLayouts.flatMap(\.terminals)
        for f in flattened {
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
        let flattened = cachedWorkspaceLayouts.flatMap(\.terminals)
        for layout in flattened where layout.title.contains(point) && !layout.close.insetBy(dx: -4, dy: -4).contains(point) {
            return layout.controller
        }
        return nil
    }

    // MARK: - Flipped Coordinates

    override var isFlipped: Bool { true }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
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
            manager.removeTerminal(controller)
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
        let flattened = cachedWorkspaceLayouts.flatMap(\.terminals)
        if let idx = thumbnailOrTitleIndex(at: point), idx < flattened.count {
            let controller = flattened[idx].controller
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
        defer {
            mouseDownTerminal = nil
            mouseDownPoint = nil
        }
        guard let controller = mouseDownTerminal else { return }

        // Navigate only if the click lands on the thumbnail content area (not the title bar)
        let point = convert(event.locationInWindow, from: nil)
        if let idx = thumbnailIndex(at: point) {
            let flattened = cachedWorkspaceLayouts.flatMap(\.terminals)
            if idx < flattened.count && flattened[idx].controller === controller {
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
        companionScrollView?.scrollWheel(with: event)
    }

    /// Read scroll offset from the companion NSScrollView and update document view height.
    private func syncWithCompanionScrollView() {
        guard let scrollView = companionScrollView else { return }
        // Read scroll position from the clip view
        scrollOffset = scrollView.contentView.bounds.origin.y
        // Update document view height to match total content
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

    override func mouseDragged(with event: NSEvent) {
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
        let point = convert(event.locationInWindow, from: nil)
        hoveredIndex = thumbnailOrTitleIndex(at: point)
        hoveredCloseID = closeButtonController(at: point)?.id
        hoveredWorkspaceClose = workspaceRemoveTarget(at: point)
        updateTooltip(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        hoveredCloseID = nil
        hoveredWorkspaceClose = nil
        hideTooltip()
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
            return .move
        }

        if pb.string(forType: .string) != nil {
            // Terminal drag: show indicator at insertion position
            dragWorkspaceIndicator = nil
            dragInsertionIndicator = computeTerminalDropIndicator(at: point)

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
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragInsertionIndicator = nil
        dragWorkspaceIndicator = nil
        stopDragAutoScroll()
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
            let allTerminals = manager.terminals
            guard !allTerminals.isEmpty else { return true }
            if allTerminals.count >= 2 {
                onMultiSelect?(allTerminals)
            } else if let single = allTerminals.first {
                onSelectTerminal?(single)
            }
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

        let sf = Float(renderer.glyphAtlas.scaleFactor)
        let time = Float(CACurrentMediaTime())
        syncWithCompanionScrollView()
        cachedWorkspaceLayouts = workspaceLayouts()

        renderPassDescriptor.colorAttachments[0].clearColor =
            MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor) else {
            return
        }

        let drawableSize = view.drawableSize
        let viewportSize = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))

        // Render workspace backgrounds (even when empty)
        for workspace in cachedWorkspaceLayouts {
            drawWorkspaceBackground(
                encoder: encoder,
                workspace: workspace,
                scaleFactor: sf,
                viewportSize: viewportSize
            )
        }

        // Render terminal thumbnails
        let flattened = cachedWorkspaceLayouts.flatMap(\.terminals)
        for (i, frame) in flattened.enumerated() {
            let controller = frame.controller
            let fontSettings = controller.persistedFontSettings
            if renderer.glyphAtlas.fontName != fontSettings.name ||
                abs(Double(renderer.glyphAtlas.fontSize) - fontSettings.size) > 0.001 {
                renderer.updateFont(name: fontSettings.name, size: CGFloat(fontSettings.size))
            }

            // Draw thumbnail border/background
            let isHovered = hoveredIndex == i
            let isSelected = selectedTerminals.contains(controller.id)
            let isActiveOutput = activeOutputTerminals.contains(controller.id)
            drawThumbnailBackground(
                encoder: encoder,
                frame: frame.thumbnail,
                titleFrame: frame.title,
                isHovered: isHovered,
                isSelected: isSelected,
                isActiveOutput: isActiveOutput,
                time: time,
                scaleFactor: sf,
                viewportSize: viewportSize
            )

            // Draw terminal content scaled to thumbnail size
            controller.withViewport { model, scrollback, scrollOffset in
                renderer.renderThumbnail(
                    model: model,
                    scrollback: scrollback,
                    scrollOffset: scrollOffset,
                    encoder: encoder,
                    viewportSize: viewportSize,
                    thumbnailRect: frame.thumbnail,
                    scaleFactor: sf
                )
            }

            // Draw title text
            drawTitle(
                encoder: encoder,
                title: controller.title,
                pid: controller.foregroundProcessID ?? controller.processID,
                shellPID: controller.processID,
                frame: frame.title,
                scaleFactor: sf,
                viewportSize: viewportSize
            )

            // Draw close button
            let isCloseHovered = hoveredCloseID == controller.id
            drawCloseButton(
                encoder: encoder,
                frame: frame.close,
                isHovered: isCloseHovered,
                scaleFactor: sf,
                viewportSize: viewportSize
            )
        }

        // Draw "Select All" / "Deselect" buttons (on top of thumbnails, only when Shift is held)
        if isShiftDown {
            for workspace in cachedWorkspaceLayouts where !workspace.terminals.isEmpty {
                drawTextButton(
                    encoder: encoder,
                    text: "Select All",
                    frame: workspace.selectAllFrame,
                    scaleFactor: sf,
                    viewportSize: viewportSize,
                    bgColor: (0.15, 0.30, 0.55, 0.9),
                    fgColor: (0.9, 0.9, 0.9, 1.0)
                )
                let hasSelection = workspace.terminals.contains { selectedTerminals.contains($0.controller.id) }
                if hasSelection {
                    drawTextButton(
                        encoder: encoder,
                        text: "Deselect",
                        frame: workspace.deselectFrame,
                        scaleFactor: sf,
                        viewportSize: viewportSize,
                        bgColor: (0.35, 0.20, 0.15, 0.9),
                        fgColor: (0.9, 0.9, 0.9, 1.0)
                    )
                }
            }
        }

        // Draw "+" button for adding new workspace
        drawAddWorkspaceButton(encoder: encoder, scaleFactor: sf, viewportSize: viewportSize)

        // Draw drag drop indicators
        drawDropIndicators(encoder: encoder, scaleFactor: sf, viewportSize: viewportSize)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Drawing Helpers

    private func drawThumbnailBackground(
        encoder: MTLRenderCommandEncoder,
        frame: NSRect,
        titleFrame: NSRect,
        isHovered: Bool,
        isSelected: Bool,
        isActiveOutput: Bool,
        time: Float,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.overlayPipeline else { return }

        let fullFrame = titleFrame.union(frame)
        let x = Float(fullFrame.origin.x) * scaleFactor
        let y = Float(fullFrame.origin.y) * scaleFactor
        let w = Float(fullFrame.width) * scaleFactor
        let h = Float(fullFrame.height) * scaleFactor

        var vertices: [Float] = []

        // Title bar background (dark gray)
        let titleX = Float(titleFrame.origin.x) * scaleFactor
        let titleY = Float(titleFrame.origin.y) * scaleFactor
        let titleW = Float(titleFrame.width) * scaleFactor
        let titleH = Float(titleFrame.height) * scaleFactor
        renderer.addQuadPublic(
            to: &vertices, x: titleX, y: titleY, w: titleW, h: titleH,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (0.15, 0.15, 0.15, 1.0),
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
            fg: (0.0, 0.0, 0.0, 1.0),
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
            borderColor = (0.9, 0.2, 0.15)
            borderWidth = Float(Layout.borderWidth)
        } else if isSelected {
            borderAlpha = 1.0
            borderColor = (0.3, 0.6, 1.0)
            borderWidth = Float(Layout.selectedBorderWidth)
        } else if isHovered {
            borderAlpha = 0.6
            borderColor = (0.4, 0.4, 0.4)
            borderWidth = Float(Layout.borderWidth)
        } else {
            borderAlpha = 0.3
            borderColor = (0.4, 0.4, 0.4)
            borderWidth = Float(Layout.borderWidth)
        }
        let bw: Float = borderWidth * scaleFactor

        // Selection overlay tint (subtle blue highlight on content area)
        if isSelected {
            renderer.addQuadPublic(
                to: &vertices, x: contentX, y: contentY, w: contentW, h: contentH,
                tx: 0, ty: 0, tw: 0, th: 0,
                fg: (0.15, 0.3, 0.6, 0.15),
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

        drawVertices(vertices, encoder: encoder, pipeline: pipeline, viewportSize: viewportSize)
    }

    private func drawWorkspaceBackground(
        encoder: MTLRenderCommandEncoder,
        workspace: WorkspaceLayout,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.overlayPipeline else { return }

        let x = Float(workspace.frame.origin.x) * scaleFactor
        let y = Float(workspace.frame.origin.y) * scaleFactor
        let w = Float(workspace.frame.width) * scaleFactor
        let h = Float(workspace.frame.height) * scaleFactor
        let bw = Float(Layout.workspaceBorderWidth) * scaleFactor

        var vertices: [Float] = []
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: w, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.07, 0.07, 0.07, 0.65), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: w, h: bw,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.28, 0.28, 0.28, 0.7), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &vertices, x: x, y: y + h - bw, w: w, h: bw,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.28, 0.28, 0.28, 0.7), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: bw, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.28, 0.28, 0.28, 0.7), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &vertices, x: x + w - bw, y: y, w: bw, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.28, 0.28, 0.28, 0.7), bg: (0, 0, 0, 0))
        drawVertices(vertices, encoder: encoder, pipeline: pipeline, viewportSize: viewportSize)

        drawWorkspaceHeaderText(
            encoder: encoder,
            text: workspace.name,
            frame: workspace.headerFrame,
            scaleFactor: scaleFactor,
            viewportSize: viewportSize
        )
        drawWorkspaceAddButton(
            encoder: encoder,
            frame: workspace.addFrame,
            scaleFactor: scaleFactor,
            viewportSize: viewportSize
        )
        drawWorkspaceCloseButton(
            encoder: encoder,
            frame: workspace.closeFrame,
            isHovered: hoveredWorkspaceClose == workspace.name,
            scaleFactor: scaleFactor,
            viewportSize: viewportSize
        )
    }

    private func drawWorkspaceHeaderText(
        encoder: MTLRenderCommandEncoder,
        text: String,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        let textX = frame.minX + Layout.closeButtonSize + 8
        let halfGlyph = renderer.glyphAtlas.cellHeight * 0.5
        drawRightAlignedTitleText(
            encoder: encoder,
            text: text,
            frame: NSRect(x: textX, y: frame.minY + halfGlyph - 4, width: frame.width - Layout.closeButtonSize - 8, height: frame.height),
            scaleFactor: scaleFactor,
            viewportSize: viewportSize,
            color: (0.9, 0.9, 0.9, 1.0),
            alignment: .left
        )
    }

    private func drawTitle(
        encoder: MTLRenderCommandEncoder,
        title: String,
        pid: pid_t,
        shellPID: pid_t,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.glyphPipeline,
              let atlas = renderer.glyphAtlas.texture else { return }

        var vertices: [Float] = []

        // Render title text character by character using the glyph atlas
        let titleChars = Array(title.unicodeScalars)
        let maxChars = Int(frame.width / renderer.glyphAtlas.cellWidth) - 2 // Leave room for close button
        let displayChars = min(titleChars.count, max(0, maxChars))

        // Title text starts after the close button area
        let textStartX = Float(frame.origin.x + Layout.closeButtonSize + 8) * scaleFactor
        let textY = Float(frame.origin.y + (Layout.titleBarHeight - renderer.glyphAtlas.cellHeight) / 2) * scaleFactor
        let cellW = Float(renderer.glyphAtlas.cellWidth) * scaleFactor
        // Scale factor for thumbnail text: render at a reasonable size
        let thumbGlyphScale: Float = 0.85

        for i in 0..<displayChars {
            let cp = titleChars[i].value
            guard cp > 0x20,
                  let glyph = renderer.glyphAtlas.glyphInfo(for: cp),
                  glyph.pixelWidth > 0 else {
                continue
            }

            let x = textStartX + Float(i) * cellW * thumbGlyphScale
            let glyphX = x + Float(glyph.bearingX) * scaleFactor * thumbGlyphScale
            let baselineScreenY = textY + Float(renderer.glyphAtlas.cellHeight) * scaleFactor * thumbGlyphScale - Float(renderer.glyphAtlas.baseline) * scaleFactor * thumbGlyphScale
            let glyphY = baselineScreenY - glyph.baselineOffset * thumbGlyphScale
            let glyphW = Float(glyph.pixelWidth) * thumbGlyphScale
            let glyphH = Float(glyph.pixelHeight) * thumbGlyphScale

            renderer.addQuadPublic(
                to: &vertices,
                x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                tx: glyph.textureX, ty: glyph.textureY,
                tw: glyph.textureW, th: glyph.textureH,
                fg: (0.8, 0.8, 0.8, 1),
                bg: (0, 0, 0, 0)
            )
        }

        if !vertices.isEmpty {
            encoder.setRenderPipelineState(pipeline)
            let buf = renderer.makeTemporaryBuffer(vertices: vertices)
            if let buf = buf {
                var uniforms = MetalRenderer.MetalUniforms(
                    viewportSize: viewportSize,
                    cursorOpacity: 0,
                    time: 0
                )
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalRenderer.MetalUniforms>.size, index: 1)
                encoder.setFragmentTexture(atlas, index: 0)
                encoder.setFragmentSamplerState(renderer.samplerState, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                      vertexCount: vertices.count / 12)
            }
        }

        if let usage = cpuUsageProvider?(pid),
           usage >= 0 {
            drawRightAlignedTitleText(
                encoder: encoder,
                text: String(format: "CPU: %.0f%%", usage),
                frame: frame,
                scaleFactor: scaleFactor,
                viewportSize: viewportSize
            )
        } else if pid != shellPID {
            // Foreground process (e.g., setuid binary) is not accessible via proc_pidinfo.
            drawRightAlignedTitleText(
                encoder: encoder,
                text: "CPU: N/A",
                frame: frame,
                scaleFactor: scaleFactor,
                viewportSize: viewportSize
            )
        }
    }

    private func drawRightAlignedTitleText(
        encoder: MTLRenderCommandEncoder,
        text: String,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        color: (Float, Float, Float, Float) = (0.55, 0.55, 0.55, 1.0),
        alignment: NSTextAlignment = .right
    ) {
        guard let pipeline = renderer.glyphPipeline,
              let atlas = renderer.glyphAtlas.texture else { return }

        let chars = Array(text.unicodeScalars)
        var vertices: [Float] = []
        let thumbGlyphScale: Float = 0.8
        let cellW = Float(renderer.glyphAtlas.cellWidth) * scaleFactor * thumbGlyphScale
        let textWidth = Float(chars.count) * cellW
        let startX: Float
        if alignment == .left {
            startX = Float(frame.minX) * scaleFactor
        } else {
            startX = Float(frame.maxX) * scaleFactor - textWidth - 8 * scaleFactor
        }
        let textY = Float(frame.origin.y + (Layout.titleBarHeight - renderer.glyphAtlas.cellHeight) / 2) * scaleFactor

        for (index, scalar) in chars.enumerated() {
            let cp = scalar.value
            guard cp > 0x20,
                  let glyph = renderer.glyphAtlas.glyphInfo(for: cp),
                  glyph.pixelWidth > 0 else {
                continue
            }

            let x = startX + Float(index) * cellW
            let glyphX = x + Float(glyph.bearingX) * scaleFactor * thumbGlyphScale
            let baselineScreenY = textY + Float(renderer.glyphAtlas.cellHeight) * scaleFactor * thumbGlyphScale - Float(renderer.glyphAtlas.baseline) * scaleFactor * thumbGlyphScale
            let glyphY = baselineScreenY - glyph.baselineOffset * thumbGlyphScale
            let glyphW = Float(glyph.pixelWidth) * thumbGlyphScale
            let glyphH = Float(glyph.pixelHeight) * thumbGlyphScale

            renderer.addQuadPublic(
                to: &vertices,
                x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                tx: glyph.textureX, ty: glyph.textureY,
                tw: glyph.textureW, th: glyph.textureH,
                fg: color,
                bg: (0, 0, 0, 0)
            )
        }

        guard !vertices.isEmpty else { return }
        encoder.setRenderPipelineState(pipeline)
        if let buf = renderer.makeTemporaryBuffer(vertices: vertices) {
            var uniforms = MetalRenderer.MetalUniforms(viewportSize: viewportSize, cursorOpacity: 0, time: 0)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalRenderer.MetalUniforms>.size, index: 1)
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.setFragmentSamplerState(renderer.samplerState, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 12)
        }
    }

    private func drawWorkspaceAddButton(
        encoder: MTLRenderCommandEncoder,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.overlayPipeline else { return }
        var vertices: [Float] = []
        let x = Float(frame.origin.x) * scaleFactor
        let y = Float(frame.origin.y) * scaleFactor
        let size = Float(frame.width) * scaleFactor
        renderer.addQuadPublic(to: &vertices, x: x, y: y, w: size, h: size,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.22, 0.22, 0.22, 0.9), bg: (0, 0, 0, 0))
        let lineW: Float = 2.0 * scaleFactor
        let lineLen: Float = size * 0.5
        let cx = x + size / 2
        let cy = y + size / 2
        renderer.addQuadPublic(to: &vertices, x: cx - lineLen / 2, y: cy - lineW / 2,
                               w: lineLen, h: lineW, tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.85, 0.85, 0.85, 1.0), bg: (0, 0, 0, 0))
        renderer.addQuadPublic(to: &vertices, x: cx - lineW / 2, y: cy - lineLen / 2,
                               w: lineW, h: lineLen, tx: 0, ty: 0, tw: 0, th: 0,
                               fg: (0.85, 0.85, 0.85, 1.0), bg: (0, 0, 0, 0))
        drawVertices(vertices, encoder: encoder, pipeline: pipeline, viewportSize: viewportSize)
    }

    private func drawTextButton(
        encoder: MTLRenderCommandEncoder,
        text: String,
        frame: NSRect,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>,
        bgColor: (Float, Float, Float, Float),
        fgColor: (Float, Float, Float, Float)
    ) {
        guard let overlayPipeline = renderer.overlayPipeline,
              let glyphPipeline = renderer.glyphPipeline,
              let atlas = renderer.glyphAtlas.texture else { return }

        // Draw background
        let x = Float(frame.origin.x) * scaleFactor
        let y = Float(frame.origin.y) * scaleFactor
        let w = Float(frame.width) * scaleFactor
        let h = Float(frame.height) * scaleFactor
        var bgVertices: [Float] = []
        renderer.addQuadPublic(to: &bgVertices, x: x, y: y, w: w, h: h,
                               tx: 0, ty: 0, tw: 0, th: 0,
                               fg: bgColor, bg: (0, 0, 0, 0))
        drawVertices(bgVertices, encoder: encoder, pipeline: overlayPipeline, viewportSize: viewportSize)

        // Draw horizontally and vertically centered text
        let chars = Array(text.unicodeScalars)
        let thumbGlyphScale: Float = 0.8
        let cellW = Float(renderer.glyphAtlas.cellWidth) * scaleFactor * thumbGlyphScale
        let cellH = Float(renderer.glyphAtlas.cellHeight) * scaleFactor * thumbGlyphScale
        let textWidth = Float(chars.count) * cellW
        let startX = x + (w - textWidth) / 2
        let startY = y + (h - cellH) / 2

        var vertices: [Float] = []
        for (index, scalar) in chars.enumerated() {
            let cp = scalar.value
            guard cp > 0x20,
                  let glyph = renderer.glyphAtlas.glyphInfo(for: cp),
                  glyph.pixelWidth > 0 else {
                continue
            }

            let cx = startX + Float(index) * cellW
            let glyphX = cx + Float(glyph.bearingX) * scaleFactor * thumbGlyphScale
            let baselineScreenY = startY + cellH - Float(renderer.glyphAtlas.baseline) * scaleFactor * thumbGlyphScale
            let glyphY = baselineScreenY - glyph.baselineOffset * thumbGlyphScale
            let glyphW = Float(glyph.pixelWidth) * thumbGlyphScale
            let glyphH = Float(glyph.pixelHeight) * thumbGlyphScale

            renderer.addQuadPublic(
                to: &vertices,
                x: glyphX, y: glyphY, w: glyphW, h: glyphH,
                tx: glyph.textureX, ty: glyph.textureY,
                tw: glyph.textureW, th: glyph.textureH,
                fg: fgColor,
                bg: (0, 0, 0, 0)
            )
        }

        guard !vertices.isEmpty else { return }
        encoder.setRenderPipelineState(glyphPipeline)
        if let buf = renderer.makeTemporaryBuffer(vertices: vertices) {
            var uniforms = MetalRenderer.MetalUniforms(viewportSize: viewportSize, cursorOpacity: 0, time: 0)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalRenderer.MetalUniforms>.size, index: 1)
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.setFragmentSamplerState(renderer.samplerState, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 12)
        }
    }

    private func drawWorkspaceCloseButton(
        encoder: MTLRenderCommandEncoder,
        frame: NSRect,
        isHovered: Bool,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        let alpha: Float = isHovered ? 0.9 : 0.7
        let bgColor: (Float, Float, Float) = isHovered ? (0.8, 0.15, 0.15) : (0.6, 0.15, 0.15)
        drawXCloseButton(
            encoder: encoder,
            frame: frame,
            bgColor: bgColor,
            bgAlpha: alpha,
            fgColor: (1, 1, 1, alpha),
            scaleFactor: scaleFactor,
            viewportSize: viewportSize
        )
    }

    /// Creates and caches an r8Unorm texture with a × icon drawn using Core Graphics.
    private func ensureCloseIconTexture() -> MTLTexture? {
        if let existing = closeIconTexture { return existing }
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

        // Clear to black (transparent in r8Unorm usage)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // Draw × with rounded line caps
        let margin = CGFloat(size) * 0.22
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineWidth(CGFloat(size) * 0.12)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: margin, y: margin))
        ctx.addLine(to: CGPoint(x: CGFloat(size) - margin, y: CGFloat(size) - margin))
        ctx.move(to: CGPoint(x: CGFloat(size) - margin, y: margin))
        ctx.addLine(to: CGPoint(x: margin, y: CGFloat(size) - margin))
        ctx.strokePath()

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

    /// Draws a × close button using a textured icon for both terminal and workspace close buttons.
    private func drawXCloseButton(
        encoder: MTLRenderCommandEncoder,
        frame: NSRect,
        bgColor: (Float, Float, Float),
        bgAlpha: Float,
        fgColor: (Float, Float, Float, Float),
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let overlayPipeline = renderer.overlayPipeline else { return }
        let x = Float(frame.origin.x) * scaleFactor
        let y = Float(frame.origin.y) * scaleFactor
        let size = Float(frame.width) * scaleFactor

        // Draw background quad
        var bgVertices: [Float] = []
        renderer.addQuadPublic(
            to: &bgVertices, x: x, y: y, w: size, h: size,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (bgColor.0, bgColor.1, bgColor.2, bgAlpha),
            bg: (0, 0, 0, 0)
        )
        drawVertices(bgVertices, encoder: encoder, pipeline: overlayPipeline, viewportSize: viewportSize)

        // Draw × icon from texture
        guard let glyphPipeline = renderer.glyphPipeline,
              let iconTexture = ensureCloseIconTexture() else { return }
        var iconVertices: [Float] = []
        // Full UV (0,0)-(1,1), icon fills the entire texture. Y is flipped for Metal.
        renderer.addQuadPublic(
            to: &iconVertices, x: x, y: y, w: size, h: size,
            tx: 0, ty: 1, tw: 1, th: -1,
            fg: (fgColor.0, fgColor.1, fgColor.2, fgColor.3),
            bg: (0, 0, 0, 0)
        )
        if let buf = renderer.makeTemporaryBuffer(vertices: iconVertices) {
            var uniforms = MetalRenderer.MetalUniforms(
                viewportSize: viewportSize,
                cursorOpacity: 0,
                time: 0
            )
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalRenderer.MetalUniforms>.size, index: 1)
            encoder.setFragmentTexture(iconTexture, index: 0)
            encoder.setFragmentSamplerState(renderer.samplerState, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                  vertexCount: iconVertices.count / 12)
        }
    }

    private func drawCloseButton(
        encoder: MTLRenderCommandEncoder,
        frame: NSRect,
        isHovered: Bool,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        let alpha: Float = isHovered ? 0.9 : 0.7
        let bgColor: (Float, Float, Float) = isHovered ? (0.8, 0.15, 0.15) : (0.6, 0.15, 0.15)
        drawXCloseButton(
            encoder: encoder,
            frame: frame,
            bgColor: bgColor,
            bgAlpha: alpha,
            fgColor: (1, 1, 1, alpha),
            scaleFactor: scaleFactor,
            viewportSize: viewportSize
        )
    }

    private func drawAddWorkspaceButton(
        encoder: MTLRenderCommandEncoder,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.overlayPipeline else { return }

        let btnSize = Layout.addButtonSize
        let margin: CGFloat = 20
        // Always fixed at bottom-right of the visible area
        let bx = bounds.width - btnSize - margin
        let by = bounds.height - btnSize - margin

        let x = Float(bx) * scaleFactor
        let y = Float(by) * scaleFactor
        let size = Float(btnSize) * scaleFactor
        var vertices: [Float] = []

        // Background
        renderer.addQuadPublic(
            to: &vertices, x: x, y: y, w: size, h: size,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (0.20, 0.24, 0.20, 0.80),
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
            fg: (0.85, 0.92, 0.85, 1.0),
            bg: (0, 0, 0, 0)
        )
        renderer.addQuadPublic(
            to: &vertices,
            x: cx - lineW / 2, y: cy - lineLen / 2,
            w: lineW, h: lineLen,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (0.85, 0.92, 0.85, 1.0),
            bg: (0, 0, 0, 0)
        )
        drawVertices(vertices, encoder: encoder, pipeline: pipeline, viewportSize: viewportSize)
        addWorkspaceButtonFrame = NSRect(x: bx, y: by, width: btnSize, height: btnSize)
    }

    private func drawVertices(
        _ vertices: [Float],
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        viewportSize: SIMD2<Float>
    ) {
        guard !vertices.isEmpty else { return }

        encoder.setRenderPipelineState(pipeline)
        let buf = renderer.makeTemporaryBuffer(vertices: vertices)
        if let buf = buf {
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

    private func drawDropIndicators(
        encoder: MTLRenderCommandEncoder,
        scaleFactor: Float,
        viewportSize: SIMD2<Float>
    ) {
        guard let pipeline = renderer.overlayPipeline else { return }
        var vertices: [Float] = []

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

        drawVertices(vertices, encoder: encoder, pipeline: pipeline, viewportSize: viewportSize)
    }

}

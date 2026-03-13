import AppKit

final class SplitTerminalContainerView: NSView {
    private enum Layout {
        /// Gap between terminal cells.
        static let gap: CGFloat = 1
    }

    private static let whiteBorder = MetalRenderer.BorderConfig(color: (1, 1, 1, 1), width: 1)
    private static let blueBorder = MetalRenderer.BorderConfig(color: (0.2, 0.5, 1.0, 1), width: 2)

    private let renderer: MetalRenderer
    private(set) var controllers: [TerminalController]
    private var scrollViews: [TerminalScrollView] = []
    /// Single MTKView overlay that renders all terminal cells.
    /// Avoids macOS CAMetalLayer compositing issues with multiple Metal layers.
    private var splitRenderView: SplitRenderView?
    private let backButton = NSButton(title: "▦", target: nil, action: nil)
    var shortcutConfiguration: ShortcutConfiguration = .default {
        didSet {
            scrollViews.forEach { $0.terminalView.shortcutConfiguration = shortcutConfiguration }
        }
    }

    var onBackToIntegrated: (() -> Void)?
    var onActiveControllerChange: ((TerminalController) -> Void)?
    var onMaximizeTerminal: ((TerminalController) -> Void)?
    var imagePreviewURLProvider: ((Int) -> URL?)? {
        didSet {
            scrollViews.forEach { $0.terminalView.imagePreviewURLProvider = imagePreviewURLProvider }
        }
    }

    init(frame: NSRect, renderer: MetalRenderer, controllers: [TerminalController]) {
        self.renderer = renderer
        self.controllers = controllers
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        backButton.bezelStyle = .texturedRounded
        backButton.isBordered = true
        backButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        backButton.contentTintColor = .white
        backButton.target = self
        backButton.action = #selector(backButtonPressed(_:))
        backButton.isHidden = true
        addSubview(backButton)
        rebuildSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func updateControllers(_ controllers: [TerminalController]) {
        self.controllers = controllers
        rebuildSubviews()
    }

    var activeController: TerminalController? {
        guard let firstResponder = window?.firstResponder else { return controllers.first }
        for scrollView in scrollViews where firstResponder === scrollView.terminalView {
            return scrollView.terminalView.terminalController
        }
        return controllers.first
    }

    var activeTerminalView: TerminalView? {
        guard let firstResponder = window?.firstResponder else {
            return scrollViews.first?.terminalView
        }
        for scrollView in scrollViews where firstResponder === scrollView.terminalView {
            return scrollView.terminalView
        }
        return scrollViews.first?.terminalView
    }

    override func layout() {
        super.layout()
        layoutGrid()
    }

    /// Compute border config for each cell: white for unfocused, blue for focused.
    private func borderConfig(for terminalView: TerminalView) -> MetalRenderer.BorderConfig? {
        guard scrollViews.count > 1 else { return nil }
        let firstResponder = window?.firstResponder
        return (firstResponder === terminalView) ? Self.blueBorder : Self.whiteBorder
    }

    private func rebuildSubviews() {
        // Remove old overlay and scroll views
        splitRenderView?.removeFromSuperview()
        splitRenderView = nil
        scrollViews.forEach { $0.removeFromSuperview() }
        scrollViews.removeAll()

        // Phase 1: Create scroll views WITHOUT assigning controllers.
        // This avoids premature terminal resizes with incorrect (full-window) bounds.
        for _ in controllers {
            let scrollView = TerminalScrollView(frame: bounds, renderer: renderer)
            scrollView.autoresizingMask = [.width, .height]
            addSubview(scrollView)
            scrollViews.append(scrollView)
        }

        // Phase 2: Set correct cell-sized frames before controllers are assigned.
        layoutGrid()

        // Phase 3: Assign controllers now that frames are correct.
        for (index, controller) in controllers.enumerated() {
            let scrollView = scrollViews[index]
            scrollView.terminalView.shortcutConfiguration = shortcutConfiguration
            // Suppress individual rendering — SplitRenderView handles it.
            // Also make the CAMetalLayer invisible so it doesn't interfere
            // with Window Server compositing of the overlay SplitRenderView.
            scrollView.terminalView.renderingSuppressed = true
            scrollView.terminalView.alphaValue = 0
            scrollView.terminalView.imagePreviewURLProvider = imagePreviewURLProvider
            scrollView.terminalView.terminalController = controller
            scrollView.terminalView.onBecameFirstResponder = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.onActiveControllerChange?(controller)
                self.syncRenderCells()
            }
            scrollView.terminalView.onBackToIntegrated = { [weak self] in
                self?.onBackToIntegrated?()
            }
            scrollView.terminalView.onCmdClick = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.onMaximizeTerminal?(controller)
            }
            scrollView.toolTip = "⌘+Click to maximize this terminal"
        }

        // Phase 4: Create single-MTKView overlay on top of all scroll views.
        let overlay = SplitRenderView(frame: bounds, renderer: renderer)
        overlay.autoresizingMask = [.width, .height]
        overlay.delegate = overlay
        overlay.borderConfigProvider = { [weak self] tv in
            self?.borderConfig(for: tv)
        }
        addSubview(overlay)
        splitRenderView = overlay
        syncRenderCells()
        applyAppearanceSettings()
    }

    /// Sync the SplitRenderView's cell references from current scroll view layout.
    private func syncRenderCells() {
        guard let overlay = splitRenderView else { return }
        var refs: [SplitRenderView.CellRef] = []
        for scrollView in scrollViews {
            guard let tv = scrollView.terminalView,
                  let controller = tv.terminalController else { continue }
            refs.append(SplitRenderView.CellRef(
                terminalView: tv,
                controller: controller,
                frame: scrollView.frame
            ))
        }
        overlay.cellRefs = refs
    }

    private func layoutGrid() {
        guard !scrollViews.isEmpty else { return }
        let gap = Layout.gap
        let (cols, rows) = TerminalManager.gridLayout(for: scrollViews.count)

        let totalGapW = gap * CGFloat(cols - 1)
        let totalGapH = gap * CGFloat(rows - 1)
        let cellWidth = max(0, (bounds.width - totalGapW) / CGFloat(cols))
        let cellHeight = max(0, (bounds.height - totalGapH) / CGFloat(rows))

        for (index, scrollView) in scrollViews.enumerated() {
            let col = index % cols
            let row = index / cols
            // Flip y so row 0 is at the top and remainder cells land at bottom-right.
            let flippedRow = rows - 1 - row
            scrollView.frame = NSRect(
                x: CGFloat(col) * (cellWidth + gap),
                y: CGFloat(flippedRow) * (cellHeight + gap),
                width: cellWidth,
                height: cellHeight
            )
        }

        splitRenderView?.frame = bounds
        syncRenderCells()
    }

    func fontSizeDidChange() {
        for scrollView in scrollViews {
            scrollView.terminalView.fontSizeDidChange()
        }
        needsLayout = true
    }

    /// Update only the IME overlay without triggering terminal resizes.
    func updateMarkedTextForFontChange() {
        for scrollView in scrollViews {
            scrollView.terminalView.updateMarkedTextOverlayPublic()
        }
    }

    func applyAppearanceSettings() {
        layer?.backgroundColor = NSColor.clear.cgColor
        for scrollView in scrollViews {
            scrollView.terminalView.applyAppearanceSettings()
        }
        splitRenderView?.applyAppearanceSettings()
    }

    func requestRender() {
        splitRenderView?.requestRender()
    }

    func releaseInactiveRenderingResourcesNow() {
        for scrollView in scrollViews {
            scrollView.terminalView.releaseInactiveRenderingResourcesNow()
        }
        splitRenderView?.releaseInactiveRenderingResourcesNow()
    }

    func compactForMemoryPressureNow() {
        for scrollView in scrollViews {
            scrollView.terminalView.compactForMemoryPressureNow()
        }
        splitRenderView?.compactForMemoryPressureNow()
    }

    func syncScaleFactorIfNeeded() {
        for scrollView in scrollViews {
            scrollView.terminalView.syncScaleFactorIfNeeded()
        }
        splitRenderView?.syncScaleFactorIfNeeded()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    @objc private func backButtonPressed(_ sender: Any?) {
        onBackToIntegrated?()
    }
}

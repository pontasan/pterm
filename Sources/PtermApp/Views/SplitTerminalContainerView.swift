import AppKit
import QuartzCore

final class SplitTerminalContainerView: NSView {
    private enum Layout {
        /// Gap between terminal cells.
        static let gap: CGFloat = 1
    }

    private static let whiteBorder = MetalRenderer.BorderConfig(color: (0.4, 0.4, 0.4, 0.3), width: 1)
    private static let blueBorder = MetalRenderer.BorderConfig(color: (0.2, 0.5, 1.0, 1), width: 2)
    private static let activeBorderRGB: (Float, Float, Float) = (0.9, 0.2, 0.15)

    private let renderer: MetalRenderer
    private(set) var controllers: [TerminalController]
    private var activeOutputTerminalIDs: Set<UUID> = []
    private(set) var selectedTerminalIDs: Set<UUID> = []
    private var commandModifierActive = false
    private var stagedSelectionModeActive = false
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
    var outputConfirmedInputAnimationsEnabled: Bool = TextInteractionConfiguration.default.outputConfirmedInputAnimation {
        didSet {
            scrollViews.forEach {
                $0.terminalView.outputConfirmedInputAnimationsEnabled = outputConfirmedInputAnimationsEnabled
            }
        }
    }
    var typewriterSoundEnabled: Bool = TextInteractionConfiguration.default.typewriterSoundEnabled {
        didSet {
            scrollViews.forEach {
                $0.terminalView.typewriterSoundEnabled = typewriterSoundEnabled
            }
        }
    }

    var onBackToIntegrated: (() -> Void)?
    var onActiveControllerChange: ((TerminalController) -> Void)?
    var onMaximizeTerminal: ((TerminalController) -> Void)?
    var onCommandClickTerminal: ((TerminalController) -> Void)?
    var onCommitSelectedControllers: (([TerminalController]) -> Void)?
    var imagePreviewURLProvider: ((Int) -> URL?)? {
        didSet {
            scrollViews.forEach { $0.terminalView.imagePreviewURLProvider = imagePreviewURLProvider }
        }
    }
    var commandClickTooltip: String = "⌘+Click to maximize this terminal" {
        didSet {
            scrollViews.forEach { $0.toolTip = commandClickTooltip }
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
        if let controller = terminalView.terminalController,
           selectedTerminalIDs.contains(controller.id) {
            return Self.blueBorder
        }
        if let controller = terminalView.terminalController,
           activeOutputTerminalIDs.contains(controller.id) {
            let pulse = Float(0.475 + 0.325 * sin(CACurrentMediaTime() * 3.0))
            return MetalRenderer.BorderConfig(
                color: (Self.activeBorderRGB.0, Self.activeBorderRGB.1, Self.activeBorderRGB.2, pulse),
                width: 1.5
            )
        }
        guard scrollViews.count > 1 else { return nil }
        if commandModifierActive || stagedSelectionModeActive {
            return Self.whiteBorder
        }
        let firstResponder = window?.firstResponder
        return (firstResponder === terminalView) ? Self.blueBorder : Self.whiteBorder
    }

    private func headerOverlayConfig(for controller: TerminalController) -> MetalRenderer.HeaderOverlayConfig? {
        guard commandModifierActive else { return nil }
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

    func setActiveOutputTerminalIDs(_ terminalIDs: Set<UUID>) {
        let relevantIDs = Set(controllers.map(\.id))
        let nextIDs = terminalIDs.intersection(relevantIDs)
        guard nextIDs != activeOutputTerminalIDs else { return }
        activeOutputTerminalIDs = nextIDs
        splitRenderView?.hasActiveOutput = !nextIDs.isEmpty
        splitRenderView?.requestRender()
    }

    private func rebuildSubviews() {
        // Remove old overlay and scroll views
        splitRenderView?.removeFromSuperview()
        splitRenderView = nil
        scrollViews.forEach { $0.removeFromSuperview() }
        scrollViews.removeAll()
        selectedTerminalIDs.removeAll()
        stagedSelectionModeActive = false

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
            scrollView.terminalView.outputConfirmedInputAnimationsEnabled = outputConfirmedInputAnimationsEnabled
            scrollView.terminalView.typewriterSoundEnabled = typewriterSoundEnabled
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
                if let onCommandClickTerminal = self.onCommandClickTerminal {
                    onCommandClickTerminal(controller)
                } else {
                    self.onMaximizeTerminal?(controller)
                }
            }
            scrollView.terminalView.onShiftCommandClick = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.toggleSplitSelection(for: controller)
            }
            scrollView.toolTip = commandClickTooltip
        }

        // Phase 4: Create single-MTKView overlay on top of all scroll views.
        let overlay = SplitRenderView(frame: bounds, renderer: renderer)
        overlay.autoresizingMask = [.width, .height]
        overlay.delegate = overlay
        overlay.borderConfigProvider = { [weak self] tv in
            self?.borderConfig(for: tv)
        }
        overlay.headerOverlayConfigProvider = { [weak self] controller in
            self?.headerOverlayConfig(for: controller)
        }
        addSubview(overlay)
        splitRenderView = overlay
        splitRenderView?.hasActiveOutput = !activeOutputTerminalIDs.isEmpty
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
        scrollViews.forEach { $0.syncScroller() }
        splitRenderView?.requestRender()
    }

    func setCommandModifierActive(_ active: Bool) {
        if commandModifierActive && !active && !selectedTerminalIDs.isEmpty {
            commitSelectedControllers()
        }
        if !active {
            stagedSelectionModeActive = false
        }
        guard commandModifierActive != active else { return }
        commandModifierActive = active
        requestRender()
    }

    func debugIdentityHeaderText(for controller: TerminalController) -> String? {
        headerOverlayConfig(for: controller)?.text
    }

    func scrubPresentedDrawableForRemoval() {
        splitRenderView?.scrubPresentedDrawableForRemoval()
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

    private func toggleSplitSelection(for controller: TerminalController) {
        stagedSelectionModeActive = true
        if selectedTerminalIDs.contains(controller.id) {
            selectedTerminalIDs.remove(controller.id)
        } else {
            selectedTerminalIDs.insert(controller.id)
        }
        requestRender()
    }

    private func commitSelectedControllers() {
        let selected = controllers.filter { selectedTerminalIDs.contains($0.id) }
        selectedTerminalIDs.removeAll()
        stagedSelectionModeActive = false
        requestRender()
        guard !selected.isEmpty else { return }
        onCommitSelectedControllers?(selected)
    }

    func debugBorderConfig(for controller: TerminalController) -> MetalRenderer.BorderConfig? {
        guard let terminalView = scrollViews.first(where: { $0.terminalView.terminalController?.id == controller.id })?.terminalView else {
            return nil
        }
        return borderConfig(for: terminalView)
    }
}

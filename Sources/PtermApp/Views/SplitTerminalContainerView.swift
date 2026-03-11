import AppKit

final class SplitTerminalContainerView: NSView {
    private enum Layout {
        static let outerPadding: CGFloat = 8
    }

    private let renderer: MetalRenderer
    private(set) var controllers: [TerminalController]
    private var scrollViews: [TerminalScrollView] = []
    private let backButton = NSButton(title: "▦", target: nil, action: nil)
    var shortcutConfiguration: ShortcutConfiguration = .default {
        didSet {
            scrollViews.forEach { $0.terminalView.shortcutConfiguration = shortcutConfiguration }
        }
    }

    var onBackToIntegrated: (() -> Void)?
    var onActiveControllerChange: ((TerminalController) -> Void)?

    init(frame: NSRect, renderer: MetalRenderer, controllers: [TerminalController]) {
        self.renderer = renderer
        self.controllers = controllers
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
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

    private func rebuildSubviews() {
        scrollViews.forEach { $0.removeFromSuperview() }
        scrollViews.removeAll()

        for controller in controllers {
            let scrollView = TerminalScrollView(frame: bounds, renderer: renderer)
            scrollView.autoresizingMask = [.width, .height]
            scrollView.terminalView.shortcutConfiguration = shortcutConfiguration
            scrollView.terminalView.terminalController = controller
            scrollView.terminalView.onBecameFirstResponder = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.onActiveControllerChange?(controller)
            }
            scrollView.terminalView.onBackToIntegrated = { [weak self] in
                self?.onBackToIntegrated?()
            }
            addSubview(scrollView)
            scrollViews.append(scrollView)
        }
        layoutGrid()
    }

    private func layoutGrid() {
        guard !scrollViews.isEmpty else { return }
        let pad: CGFloat = Layout.outerPadding
        let (cols, rows) = TerminalManager.gridLayout(for: scrollViews.count)
        let usableHeight = max(0, bounds.height)
        let cellWidth = max(0, (bounds.width - pad * CGFloat(cols + 1)) / CGFloat(cols))
        let cellHeight = max(0, (usableHeight - pad * CGFloat(rows + 1)) / CGFloat(rows))

        for (index, scrollView) in scrollViews.enumerated() {
            let col = index % cols
            let row = index / cols
            scrollView.frame = NSRect(
                x: pad + CGFloat(col) * (cellWidth + pad),
                y: pad + CGFloat(row) * (cellHeight + pad),
                width: cellWidth,
                height: cellHeight
            )
        }
    }

    func fontSizeDidChange() {
        for scrollView in scrollViews {
            scrollView.terminalView.fontSizeDidChange()
            scrollView.terminalView.setNeedsDisplay(scrollView.terminalView.bounds)
        }
        needsLayout = true
    }

    /// Update only the IME overlay without triggering terminal resizes.
    func updateMarkedTextForFontChange() {
        for scrollView in scrollViews {
            scrollView.terminalView.updateMarkedTextOverlayPublic()
        }
    }

    @objc private func backButtonPressed(_ sender: Any?) {
        onBackToIntegrated?()
    }
}

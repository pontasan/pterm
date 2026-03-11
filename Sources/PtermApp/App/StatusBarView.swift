import AppKit

final class StatusBarView: NSView {
    private let metricsLabel = NSTextField(labelWithString: "CPU: --% | MEM: -- MB")
    private var currentCpu: Double = 0
    private var currentMemBytes: UInt64 = 0
    private let backButton: NSButton
    var onBackToIntegrated: (() -> Void)?

    override init(frame frameRect: NSRect) {
        backButton = NSButton(title: "◀ 統合ビュー", target: nil, action: nil)
        super.init(frame: frameRect)
        backButton.target = self
        backButton.action = #selector(backButtonClicked)

        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor

        let textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        metricsLabel.textColor = textColor
        metricsLabel.font = font
        metricsLabel.alignment = .right
        addSubview(metricsLabel)

        backButton.bezelStyle = .recessed
        backButton.isBordered = false
        backButton.contentTintColor = textColor
        backButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        backButton.toolTip = "統合ビューに戻る (Cmd+`)"
        backButton.isHidden = true
        addSubview(backButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 12
        let vertInset: CGFloat = 4
        let height = bounds.height - vertInset * 2

        backButton.sizeToFit()
        if !backButton.isHidden {
            backButton.frame = NSRect(x: inset, y: vertInset, width: backButton.frame.width, height: height)
        }

        metricsLabel.sizeToFit()
        let metricsX = bounds.width - inset - metricsLabel.frame.width
        metricsLabel.frame = NSRect(x: metricsX, y: vertInset, width: metricsLabel.frame.width, height: height)
    }

    func updateMemoryUsage(bytes: UInt64) {
        currentMemBytes = bytes
        refreshMetricsLabel()
    }

    func updateCpuUsage(percent: Double) {
        currentCpu = percent
        refreshMetricsLabel()
    }

    private func refreshMetricsLabel() {
        let megabytes = Double(currentMemBytes) / (1024 * 1024)
        metricsLabel.stringValue = String(format: "CPU: %.0f%% | MEM: %.0fMB", currentCpu, megabytes)
        needsLayout = true
    }

    func setBackButtonVisible(_ visible: Bool) {
        backButton.isHidden = !visible
        needsLayout = true
    }

    @objc private func backButtonClicked() {
        onBackToIntegrated?()
    }
}

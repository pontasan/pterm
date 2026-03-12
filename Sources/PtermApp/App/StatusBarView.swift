import AppKit

final class StatusBarView: NSView {
    private let metricsLabel = NSTextField(labelWithString: "CPU: --% | MEM: -- MB")
    private var currentCpu: Double = 0
    private var currentMemBytes: UInt64 = 0
    private let backButton: NSButton
    private let separatorLabel: NSTextField
    private let noteButton: NSButton
    var onBackToIntegrated: (() -> Void)?
    var onOpenNote: (() -> Void)?

    override init(frame frameRect: NSRect) {
        backButton = NSButton(title: "◀ Overview", target: nil, action: nil)
        separatorLabel = NSTextField(labelWithString: "|")
        noteButton = NSButton(title: "Edit Notes", target: nil, action: nil)
        super.init(frame: frameRect)
        backButton.target = self
        backButton.action = #selector(backButtonClicked)
        noteButton.target = self
        noteButton.action = #selector(noteButtonClicked)

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
        backButton.toolTip = "Back to Overview (Cmd+`)"
        backButton.isHidden = true
        addSubview(backButton)

        separatorLabel.textColor = NSColor(calibratedWhite: 0.4, alpha: 1)
        separatorLabel.font = font
        separatorLabel.isHidden = true
        addSubview(separatorLabel)

        noteButton.bezelStyle = .recessed
        noteButton.isBordered = false
        noteButton.contentTintColor = textColor
        noteButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        noteButton.toolTip = "Edit Notes"
        addSubview(noteButton)
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
        let spacing: CGFloat = 6

        // Left side: [backButton] [separator] [noteButton] when back is visible
        //            [noteButton] when back is hidden
        var x = inset

        if !backButton.isHidden {
            backButton.sizeToFit()
            backButton.frame = NSRect(x: x, y: vertInset, width: backButton.frame.width, height: height)
            x = backButton.frame.maxX + spacing

            separatorLabel.sizeToFit()
            separatorLabel.frame = NSRect(x: x, y: vertInset, width: separatorLabel.frame.width, height: height)
            x = separatorLabel.frame.maxX + spacing
        }

        noteButton.sizeToFit()
        noteButton.frame = NSRect(x: x, y: vertInset, width: noteButton.frame.width, height: height)

        // Right side: metrics
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
        separatorLabel.isHidden = !visible
        needsLayout = true
    }

    @objc private func backButtonClicked() {
        onBackToIntegrated?()
    }

    @objc private func noteButtonClicked() {
        onOpenNote?()
    }
}

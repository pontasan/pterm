import AppKit

final class StatusBarView: NSView {
    private enum Style {
        case solid
        case translucent
    }

    private let metricsLabel = NSTextField(labelWithString: "CPU: --.-% | MEM: -- MB")
    private let metricsTemplateLabel = NSTextField(labelWithString: "CPU: 999.9% | MEM: 99999MB")
    private var currentCpu: Double = 0
    private var currentMemBytes: UInt64 = 0
    private var metricsLabelWidth: CGFloat = 0
    private let backButton: NSButton
    private let separatorLabel: NSTextField
    private let noteButton: NSButton
    private var style: Style = .solid
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
        applyCurrentStyle()

        let textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        metricsLabel.textColor = textColor
        metricsLabel.font = font
        metricsLabel.alignment = .right
        addSubview(metricsLabel)
        metricsTemplateLabel.font = font
        metricsTemplateLabel.sizeToFit()
        metricsLabelWidth = ceil(metricsTemplateLabel.frame.width)

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
        let metricsX = bounds.width - inset - metricsLabelWidth
        metricsLabel.frame = NSRect(x: metricsX, y: vertInset, width: metricsLabelWidth, height: height)
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
        let formatted = String(format: "CPU: %.1f%% | MEM: %.0fMB", currentCpu, megabytes)
        guard metricsLabel.stringValue != formatted else { return }
        metricsLabel.stringValue = formatted
    }

    func setBackButtonVisible(_ visible: Bool) {
        backButton.isHidden = !visible
        separatorLabel.isHidden = !visible
        needsLayout = true
    }

    func setTranslucentBackground(_ translucent: Bool) {
        let newStyle: Style = translucent ? .translucent : .solid
        guard style != newStyle else { return }
        style = newStyle
        applyCurrentStyle()
    }

    private func applyCurrentStyle() {
        switch style {
        case .solid:
            layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        case .translucent:
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    @objc private func backButtonClicked() {
        onBackToIntegrated?()
    }

    @objc private func noteButtonClicked() {
        onOpenNote?()
    }
}

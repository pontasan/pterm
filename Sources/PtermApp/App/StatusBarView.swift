import AppKit

final class StatusBarView: NSView {
    private enum Style {
        case solid
        case translucent
    }

    private let metricsLabel = NSTextField(labelWithString: "CPU: --.-% | MEM: -- MB")
    private let metricsTemplateLabel = NSTextField(labelWithString: "CPU: 999.9% | MEM: 99999MB")
    private let overviewHintLabel = NSTextField(labelWithString: "Cmd+A: Show all terminals")
    private let overviewHintSeparatorLabel = NSTextField(labelWithString: "|")
    private var currentCpu: Double = 0
    private var currentMemBytes: UInt64 = 0
    private var metricsLabelWidth: CGFloat = 0
    private let backButton: NSButton
    private let separatorLabel: NSTextField
    private let noteButton: NSButton
    private let commandHintSeparatorLabel: NSTextField
    private let commandHintLabel: NSTextField
    private let multiSelectHintSeparatorLabel: NSTextField
    private let multiSelectHintLabel: NSTextField
    private let commandClickHintSeparatorLabel: NSTextField
    private let commandClickHintLabel: NSTextField
    private var multiSelectHintText: String?
    private var commandClickHintText: String?
    private var style: Style = .solid
    var onBackToIntegrated: (() -> Void)?
    var onOpenNote: (() -> Void)?

    override init(frame frameRect: NSRect) {
        backButton = NSButton(title: "◀ Overview", target: nil, action: nil)
        separatorLabel = NSTextField(labelWithString: "|")
        noteButton = NSButton(title: "Edit Notes", target: nil, action: nil)
        commandHintSeparatorLabel = NSTextField(labelWithString: "|")
        commandHintLabel = NSTextField(labelWithString: "Cmd: Show identities")
        multiSelectHintSeparatorLabel = NSTextField(labelWithString: "|")
        multiSelectHintLabel = NSTextField(labelWithString: "")
        commandClickHintSeparatorLabel = NSTextField(labelWithString: "|")
        commandClickHintLabel = NSTextField(labelWithString: "")
        super.init(frame: frameRect)
        backButton.target = self
        backButton.action = #selector(backButtonClicked)
        backButton.identifier = NSUserInterfaceItemIdentifier("statusbar.backButton")
        noteButton.target = self
        noteButton.action = #selector(noteButtonClicked)
        noteButton.identifier = NSUserInterfaceItemIdentifier("statusbar.noteButton")

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
        separatorLabel.identifier = NSUserInterfaceItemIdentifier("statusbar.overviewSeparator")
        addSubview(separatorLabel)

        noteButton.bezelStyle = .recessed
        noteButton.isBordered = false
        noteButton.contentTintColor = textColor
        noteButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        noteButton.toolTip = "Edit Notes"
        addSubview(noteButton)

        commandHintSeparatorLabel.textColor = NSColor(calibratedWhite: 0.4, alpha: 1)
        commandHintSeparatorLabel.font = font
        commandHintSeparatorLabel.identifier = NSUserInterfaceItemIdentifier("statusbar.commandSeparator")
        addSubview(commandHintSeparatorLabel)

        commandHintLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        commandHintLabel.font = font
        commandHintLabel.lineBreakMode = .byTruncatingTail
        commandHintLabel.identifier = NSUserInterfaceItemIdentifier("statusbar.commandHint")
        addSubview(commandHintLabel)

        multiSelectHintSeparatorLabel.textColor = NSColor(calibratedWhite: 0.4, alpha: 1)
        multiSelectHintSeparatorLabel.font = font
        multiSelectHintSeparatorLabel.identifier = NSUserInterfaceItemIdentifier("statusbar.multiSelectSeparator")
        multiSelectHintSeparatorLabel.isHidden = true
        addSubview(multiSelectHintSeparatorLabel)

        multiSelectHintLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        multiSelectHintLabel.font = font
        multiSelectHintLabel.lineBreakMode = .byTruncatingTail
        multiSelectHintLabel.identifier = NSUserInterfaceItemIdentifier("statusbar.multiSelectHint")
        multiSelectHintLabel.isHidden = true
        addSubview(multiSelectHintLabel)

        commandClickHintSeparatorLabel.textColor = NSColor(calibratedWhite: 0.4, alpha: 1)
        commandClickHintSeparatorLabel.font = font
        commandClickHintSeparatorLabel.identifier = NSUserInterfaceItemIdentifier("statusbar.commandClickSeparator")
        addSubview(commandClickHintSeparatorLabel)

        commandClickHintLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        commandClickHintLabel.font = font
        commandClickHintLabel.lineBreakMode = .byTruncatingTail
        commandClickHintLabel.identifier = NSUserInterfaceItemIdentifier("statusbar.commandClickHint")
        commandClickHintLabel.isHidden = true
        addSubview(commandClickHintLabel)

        commandClickHintSeparatorLabel.isHidden = true

        overviewHintLabel.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        overviewHintLabel.font = font
        overviewHintLabel.lineBreakMode = .byTruncatingTail
        overviewHintLabel.isHidden = true
        overviewHintLabel.identifier = NSUserInterfaceItemIdentifier("statusbar.overviewHint")
        addSubview(overviewHintLabel)

        overviewHintSeparatorLabel.textColor = NSColor(calibratedWhite: 0.4, alpha: 1)
        overviewHintSeparatorLabel.font = font
        overviewHintSeparatorLabel.isHidden = true
        overviewHintSeparatorLabel.identifier = NSUserInterfaceItemIdentifier("statusbar.overviewHintSeparator")
        addSubview(overviewHintSeparatorLabel)
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

        // Left side: [backButton] [separator] [noteButton] [separator] [Cmd hint]
        //            [separator] [Shift+Cmd+Click hint] [separator] [Cmd+Click hint]
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
        x = noteButton.frame.maxX + spacing

        commandHintSeparatorLabel.sizeToFit()
        commandHintSeparatorLabel.frame = NSRect(x: x, y: vertInset, width: commandHintSeparatorLabel.frame.width, height: height)
        x = commandHintSeparatorLabel.frame.maxX + spacing

        commandHintLabel.sizeToFit()
        commandHintLabel.frame = NSRect(x: x, y: vertInset, width: commandHintLabel.frame.width, height: height)
        x = commandHintLabel.frame.maxX + spacing

        if !multiSelectHintLabel.isHidden {
            multiSelectHintSeparatorLabel.sizeToFit()
            multiSelectHintSeparatorLabel.frame = NSRect(x: x, y: vertInset, width: multiSelectHintSeparatorLabel.frame.width, height: height)
            x = multiSelectHintSeparatorLabel.frame.maxX + spacing

            multiSelectHintLabel.sizeToFit()
            multiSelectHintLabel.frame = NSRect(x: x, y: vertInset, width: multiSelectHintLabel.frame.width, height: height)
            x = multiSelectHintLabel.frame.maxX + spacing
        }

        if !commandClickHintLabel.isHidden {
            commandClickHintSeparatorLabel.sizeToFit()
            commandClickHintSeparatorLabel.frame = NSRect(x: x, y: vertInset, width: commandClickHintSeparatorLabel.frame.width, height: height)
            x = commandClickHintSeparatorLabel.frame.maxX + spacing

            commandClickHintLabel.sizeToFit()
            commandClickHintLabel.frame = NSRect(x: x, y: vertInset, width: commandClickHintLabel.frame.width, height: height)
        }

        // Right side: metrics
        let metricsX = bounds.width - inset - metricsLabelWidth
        metricsLabel.frame = NSRect(x: metricsX, y: vertInset, width: metricsLabelWidth, height: height)

        if !overviewHintLabel.isHidden {
            overviewHintSeparatorLabel.sizeToFit()
            overviewHintSeparatorLabel.frame = NSRect(
                x: noteButton.frame.maxX + spacing,
                y: vertInset,
                width: overviewHintSeparatorLabel.frame.width,
                height: height
            )
            let hintMinX = overviewHintSeparatorLabel.frame.maxX + spacing
            let hintMaxX = metricsLabel.frame.minX - 12
            let availableWidth = max(0, hintMaxX - hintMinX)
            overviewHintLabel.frame = NSRect(x: hintMinX, y: vertInset, width: availableWidth, height: height)
        }
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

    func setOverviewSelectAllHintVisible(_ visible: Bool) {
        overviewHintLabel.isHidden = !visible
        overviewHintSeparatorLabel.isHidden = !visible
        needsLayout = true
    }

    func setCommandClickHint(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = !(trimmed?.isEmpty ?? true)
        commandClickHintText = visible ? trimmed : nil
        commandClickHintLabel.stringValue = commandClickHintText ?? ""
        commandClickHintLabel.isHidden = !visible
        commandClickHintSeparatorLabel.isHidden = !visible
        needsLayout = true
    }

    func setMultiSelectHint(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = !(trimmed?.isEmpty ?? true)
        multiSelectHintText = visible ? trimmed : nil
        multiSelectHintLabel.stringValue = multiSelectHintText ?? ""
        multiSelectHintLabel.isHidden = !visible
        multiSelectHintSeparatorLabel.isHidden = !visible
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

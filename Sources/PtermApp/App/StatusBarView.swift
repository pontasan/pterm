import AppKit

final class StatusBarView: NSView {
    private enum Style {
        case solid
        case translucent
    }

    private let metricsLabel = NSTextField(labelWithString: "CPU: --.-% | MEM: -- MB")
    private let metricsTemplateLabel = NSTextField(labelWithString: "")
    private let shiftSelectHintLabel = NSTextField(labelWithString: "Shift+Click: Select multiple")
    private let shiftSelectHintSeparatorLabel = NSTextField(labelWithString: "|")
    private let overviewHintLabel = NSTextField(labelWithString: "Cmd+A: Show all terminals")
    private let overviewHintSeparatorLabel = NSTextField(labelWithString: "|")
    private var currentCpu: Double = 0
    private var currentMemBytes: UInt64 = 0
    private var currentFPS: Double?
    private var showsFPSInStatusBar = false
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
        refreshMetricsTemplateWidth()

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

        shiftSelectHintLabel.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        shiftSelectHintLabel.font = font
        shiftSelectHintLabel.lineBreakMode = .byTruncatingTail
        shiftSelectHintLabel.isHidden = true
        shiftSelectHintLabel.identifier = NSUserInterfaceItemIdentifier("statusbar.shiftSelectHint")
        addSubview(shiftSelectHintLabel)

        shiftSelectHintSeparatorLabel.textColor = NSColor(calibratedWhite: 0.4, alpha: 1)
        shiftSelectHintSeparatorLabel.font = font
        shiftSelectHintSeparatorLabel.isHidden = true
        shiftSelectHintSeparatorLabel.identifier = NSUserInterfaceItemIdentifier("statusbar.shiftSelectHintSeparator")
        addSubview(shiftSelectHintSeparatorLabel)

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
        let metricsGap: CGFloat = 12

        // Right side: metrics
        let metricsX = bounds.width - inset - metricsLabelWidth
        metricsLabel.frame = NSRect(x: metricsX, y: vertInset, width: metricsLabelWidth, height: height)
        let contentMaxX = metricsLabel.frame.minX - metricsGap

        // Left side: [backButton] [separator] [noteButton] [separator] [Cmd hint]
        //            [separator] [Shift+Cmd+Click hint] [separator] [Cmd+Click hint]
        var x = inset

        func placeSeparator(_ label: NSTextField, at originX: CGFloat) -> CGFloat {
            label.sizeToFit()
            label.frame = NSRect(x: originX, y: vertInset, width: label.frame.width, height: height)
            return label.frame.maxX + spacing
        }

        func placeTruncatingLabel(_ label: NSTextField, at originX: CGFloat) -> CGFloat {
            let fittingSize = label.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude, height: height))
            let width = max(0, min(ceil(fittingSize.width), contentMaxX - originX))
            label.frame = NSRect(x: originX, y: vertInset, width: width, height: height)
            return label.frame.maxX + spacing
        }

        if !backButton.isHidden {
            backButton.sizeToFit()
            backButton.frame = NSRect(x: x, y: vertInset, width: backButton.frame.width, height: height)
            x = backButton.frame.maxX + spacing

            x = placeSeparator(separatorLabel, at: x)
        }

        noteButton.sizeToFit()
        noteButton.frame = NSRect(x: x, y: vertInset, width: noteButton.frame.width, height: height)
        x = noteButton.frame.maxX + spacing

        if !commandHintLabel.isHidden {
            x = placeSeparator(commandHintSeparatorLabel, at: x)
            x = placeTruncatingLabel(commandHintLabel, at: x)
        }

        if !multiSelectHintLabel.isHidden {
            x = placeSeparator(multiSelectHintSeparatorLabel, at: x)

            x = placeTruncatingLabel(multiSelectHintLabel, at: x)
        }

        if !commandClickHintLabel.isHidden {
            x = placeSeparator(commandClickHintSeparatorLabel, at: x)

            x = placeTruncatingLabel(commandClickHintLabel, at: x)
        }

        if !shiftSelectHintLabel.isHidden {
            x = placeSeparator(shiftSelectHintSeparatorLabel, at: x)
            x = placeTruncatingLabel(shiftSelectHintLabel, at: x)
        }

        if !overviewHintLabel.isHidden {
            x = placeSeparator(overviewHintSeparatorLabel, at: x)
            _ = placeTruncatingLabel(overviewHintLabel, at: x)
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

    func updateFPS(_ fps: Double?) {
        currentFPS = fps
        refreshMetricsLabel()
    }

    func setFPSVisible(_ visible: Bool) {
        guard showsFPSInStatusBar != visible else { return }
        showsFPSInStatusBar = visible
        if !visible {
            currentFPS = nil
        }
        refreshMetricsTemplateWidth()
        refreshMetricsLabel()
        needsLayout = true
    }

    private func refreshMetricsTemplateWidth() {
        metricsTemplateLabel.stringValue = showsFPSInStatusBar
            ? "CPU: 999.9% | MEM: 99999MB | FPS: 999.9"
            : "CPU: 999.9% | MEM: 99999MB"
        metricsTemplateLabel.sizeToFit()
        metricsLabelWidth = ceil(metricsTemplateLabel.frame.width)
    }

    private func refreshMetricsLabel() {
        let megabytes = Double(currentMemBytes) / (1024 * 1024)
        let formatted: String
        if showsFPSInStatusBar {
            let fpsText = currentFPS.map { String(format: "%.1f", $0) } ?? "--.-"
            formatted = String(format: "CPU: %.1f%% | MEM: %.0fMB | FPS: %@", currentCpu, megabytes, fpsText)
        } else {
            formatted = String(format: "CPU: %.1f%% | MEM: %.0fMB", currentCpu, megabytes)
        }
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
        shiftSelectHintLabel.isHidden = !visible
        shiftSelectHintSeparatorLabel.isHidden = !visible
        needsLayout = true
    }

    func setCommandHintVisible(_ visible: Bool) {
        guard commandHintLabel.isHidden == visible else { return }
        commandHintLabel.isHidden = !visible
        commandHintSeparatorLabel.isHidden = !visible
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

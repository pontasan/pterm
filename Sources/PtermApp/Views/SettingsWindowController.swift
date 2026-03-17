import AppKit

// MARK: - Flipped container for top-left origin layout

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsContentView: FlippedView {
    var sidebarWidth: CGFloat = 160
    var sidebarScroll: NSScrollView?
    var separator: NSBox?
    var contentScroll: NSScrollView?

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        let b = bounds
        sidebarScroll?.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: b.height)
        separator?.frame = NSRect(x: sidebarWidth, y: 0, width: 1, height: b.height)
        contentScroll?.frame = NSRect(x: sidebarWidth + 1, y: 0, width: b.width - sidebarWidth - 1, height: b.height)
    }
}

// MARK: - Settings Window Controller

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let settingsLabelColumnWidth: CGFloat = 160
    private let settingsControlSpacing: CGFloat = 8
    private enum Section: Int, CaseIterable {
        case general = 0
        case appearance
        case memory
        case security
        case audit

        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .memory: return "Memory"
            case .security: return "Security"
            case .audit: return "Audit"
            }
        }

        var iconName: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "textformat"
            case .memory: return "memorychip"
            case .security: return "lock.shield"
            case .audit: return "doc.text.magnifyingglass"
            }
        }
    }

    private let sidebarWidth: CGFloat = 160
    private let contentPadding: CGFloat = 24
    private var sidebarTableView: NSTableView!
    private var contentScroll: NSScrollView!
    private var currentSection: Section = .general
    private var configData: [String: Any] = [:]
    private let configURL: URL
    var onClose: (() -> Void)?

    // Control references
    private var termPopup: NSPopUpButton?
    private var launchShellsTableView: NSTableView?
    private var launchShellsValues: [String] = []
    private var encodingPopup: NSPopUpButton?
    private var outputConfirmedInputAnimationCheck: NSButton?
    private var typewriterSoundCheck: NSButton?
    private var scrollPersistenceCheck: NSButton?
    private var mcpServerEnabledCheck: NSButton?
    private var mcpServerPortField: NSTextField?
    private var fontNameLabel: NSTextField?
    private var fontSizeStepper: NSStepper?
    private var fontSizeField: NSTextField?
    private var selectedFontName: String?
    private var selectedFontSize: Double?
    private var terminalForegroundWell: NSColorWell?
    private var terminalForegroundHexLabel: NSTextField?
    private var terminalBackgroundWell: NSColorWell?
    private var terminalBackgroundHexLabel: NSTextField?
    private var terminalBackgroundOpacitySlider: NSSlider?
    private var terminalBackgroundOpacityValueLabel: NSTextField?
    private var memoryMaxField: NSTextField?
    private var memoryInitialField: NSTextField?
    private var osc52Check: NSButton?
    private var pasteConfirmCheck: NSButton?
    private var mouseRestrictCheck: NSButton?
    private var windowResizeCheck: NSButton?
    private var auditEnabledCheck: NSButton?
    private var retentionField: NSTextField?
    private var encryptCheck: NSButton?
    private var factoryResetButton: NSButton?

    init(configURL: URL = PtermDirectories.config) {
        self.configURL = configURL
        let contentRect = NSRect(x: 0, y: 0, width: 640, height: 480)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(contentRect: contentRect, styleMask: styleMask,
                              backing: .buffered, defer: false)
        window.title = "Settings"
        window.minSize = NSSize(width: 540, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)

        super.init(window: window)
        window.delegate = self

        loadConfigData()
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func showWindow() {
        loadConfigData()
        showContentForSection(currentSection)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: - Config I/O

    private func loadConfigData() {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            configData = [:]
            return
        }
        configData = json
    }

    private func saveConfigData() throws {
        let data = try JSONSerialization.data(withJSONObject: configData,
                                              options: [.prettyPrinted, .sortedKeys])
        try AtomicFileWriter.write(data, to: configURL, permissions: 0o600)
    }

    private func commitConfigChange() {
        do {
            try saveConfigData()
        } catch {
            loadConfigData()
            showContentForSection(currentSection)
            NSAlert(error: error).runModal()
        }
    }

    func resetToFactoryDefaults() {
        configData = Self.factoryResetConfigData(configData)
        commitConfigChange()
        showContentForSection(currentSection)
    }

    private static func factoryResetConfigData(_ configData: [String: Any]) -> [String: Any] {
        var reset = configData
        reset.removeValue(forKey: "term")
        reset.removeValue(forKey: "text_encoding")
        reset.removeValue(forKey: "memory_max")
        reset.removeValue(forKey: "memory_initial")
        reset.removeValue(forKey: "font")
        reset.removeValue(forKey: "font_name")
        reset.removeValue(forKey: "font_size")

        func resetSection(_ key: String, removing managedKeys: Set<String>) {
            guard var section = reset[key] as? [String: Any] else { return }
            for managedKey in managedKeys {
                section.removeValue(forKey: managedKey)
            }
            if section.isEmpty {
                reset.removeValue(forKey: key)
            } else {
                reset[key] = section
            }
        }

        resetSection("session", removing: ["scroll_buffer_persistence"])
        resetSection("shells", removing: ["launch_order"])
        resetSection("text_interaction", removing: ["output_confirmed_input_animation", "typewriter_sound_enabled"])
        resetSection("appearance", removing: [
            "terminal_foreground_color",
            "terminal_background_color",
            "terminal_background_opacity"
        ])
        resetSection("security", removing: [
            "osc52_clipboard_read",
            "paste_confirmation",
            "mouse_report_restrict_alternate_screen",
            "allow_window_resize_sequence"
        ])
        resetSection("mcp_server", removing: [
            "enabled",
            "port"
        ])
        resetSection("audit", removing: [
            "enabled",
            "retention_days",
            "encryption"
        ])

        return reset
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window else { return }
        let bounds = window.contentView!.bounds

        let root = SettingsContentView(frame: bounds)
        root.autoresizingMask = [.width, .height]
        root.sidebarWidth = sidebarWidth
        window.contentView = root

        // Sidebar
        let sidebarScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height))
        sidebarScroll.autoresizingMask = [.height]
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.borderType = .noBorder

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 32
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.width = sidebarWidth - 4
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self

        sidebarScroll.documentView = tableView
        sidebarTableView = tableView
        root.addSubview(sidebarScroll)
        root.sidebarScroll = sidebarScroll

        // Separator
        let separator = NSBox(frame: NSRect(x: sidebarWidth, y: 0, width: 1, height: bounds.height))
        separator.autoresizingMask = [.height]
        separator.boxType = .separator
        root.addSubview(separator)
        root.separator = separator

        // Content scroll view
        let contentX = sidebarWidth + 1
        let scrollView = NSScrollView(frame: NSRect(x: contentX, y: 0,
                                                     width: bounds.width - contentX, height: bounds.height))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        root.addSubview(scrollView)
        contentScroll = scrollView
        root.contentScroll = scrollView

        sidebarTableView.reloadData()
        sidebarTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showContentForSection(.general)
    }

    private func showContentForSection(_ section: Section) {
        currentSection = section

        let documentView = FlippedView()
        let contentWidth: CGFloat = 400
        var y: CGFloat = contentPadding

        func addView(_ view: NSView, height: CGFloat) {
            view.frame = NSRect(x: contentPadding, y: y, width: contentWidth, height: height)
            documentView.addSubview(view)
            y += height
        }

        func addSpacing(_ h: CGFloat) {
            y += h
        }

        switch section {
        case .general: buildGeneral(addView: addView, addSpacing: addSpacing, width: contentWidth)
        case .appearance: buildAppearance(addView: addView, addSpacing: addSpacing, width: contentWidth)
        case .memory: buildMemory(addView: addView, addSpacing: addSpacing, width: contentWidth)
        case .security: buildSecurity(addView: addView, addSpacing: addSpacing, width: contentWidth)
        case .audit: buildAudit(addView: addView, addSpacing: addSpacing, width: contentWidth)
        }

        y += contentPadding
        let scrollWidth = contentScroll.bounds.width
        documentView.frame = NSRect(x: 0, y: 0,
                                     width: max(scrollWidth, contentWidth + contentPadding * 2),
                                     height: y)
        contentScroll.documentView = documentView
    }

    // MARK: - Section: General

    private func buildGeneral(addView: (NSView, CGFloat) -> Void, addSpacing: (CGFloat) -> Void, width: CGFloat) {
        addView(makeSectionTitle("General"), 28)
        addSpacing(12)

        let termValues = ["xterm-256color", "xterm", "vt100"]
        let currentTerm = stringValue("term") ?? "xterm-256color"
        let (termRow, popup) = makePopupRow(label: "TERM:", values: termValues,
                                             current: currentTerm, width: width)
        popup.target = self
        popup.action = #selector(termChanged(_:))
        termPopup = popup
        addView(termRow, 28)
        addSpacing(12)

        let currentShells = configuredLaunchShells()
        launchShellsValues = currentShells
        let shellRow = makeLaunchShellsEditor(width: width)
        addView(shellRow, 148)
        addSpacing(4)
        addView(
            makeDescriptionLabel(
                "New terminals try shells in this order. Edit paths directly, then move rows up or down.",
                width: width
            ),
            28
        )
        addSpacing(12)

        let encDisplay = ["UTF-8", "UTF-16", "UTF-16LE", "UTF-16BE"]
        let encConfig = ["utf-8", "utf-16", "utf-16le", "utf-16be"]
        let currentEnc = stringValue("text_encoding") ?? "utf-8"
        let encIndex = encConfig.firstIndex(of: currentEnc) ?? 0
        let (encRow, encPopup) = makePopupRow(label: "Text Encoding:", values: encDisplay,
                                               current: encDisplay[encIndex], width: width)
        encPopup.target = self
        encPopup.action = #selector(encodingChanged(_:))
        encodingPopup = encPopup
        addView(encRow, 28)
        addSpacing(12)

        let textInteraction = configData["text_interaction"] as? [String: Any]
        let outputConfirmedInputAnimation = (textInteraction?["output_confirmed_input_animation"] as? Bool) ?? TextInteractionConfiguration.default.outputConfirmedInputAnimation
        let outputConfirmedCheck = makeCheckbox(
            "Output-confirm input animations",
            checked: outputConfirmedInputAnimation
        )
        outputConfirmedCheck.target = self
        outputConfirmedCheck.action = #selector(outputConfirmedInputAnimationChanged(_:))
        outputConfirmedInputAnimationCheck = outputConfirmedCheck
        addView(outputConfirmedCheck, 22)
        addSpacing(2)
        addView(
            makeDescriptionLabel(
                "When enabled, input and delete animations start only after matching PTY output confirms the visible result.",
                width: width
            ),
            28
        )
        addSpacing(12)

        let typewriterSoundEnabled = (textInteraction?["typewriter_sound_enabled"] as? Bool) ?? TextInteractionConfiguration.default.typewriterSoundEnabled
        let typewriterSoundCheckbox = makeCheckbox(
            "Simulate typewriter keystroke sounds",
            checked: typewriterSoundEnabled
        )
        typewriterSoundCheckbox.target = self
        typewriterSoundCheckbox.action = #selector(typewriterSoundChanged(_:))
        typewriterSoundCheck = typewriterSoundCheckbox
        addView(typewriterSoundCheckbox, 22)
        addSpacing(2)
        addView(
            makeDescriptionLabel(
                "Simulate mechanical typewriter keystroke sounds whenever terminal input is committed.",
                width: width
            ),
            28
        )
        addSpacing(16)

        let session = configData["session"] as? [String: Any]
        let persistence = (session?["scroll_buffer_persistence"] as? Bool) ?? false
        let check = makeCheckbox("Persist scroll buffer across sessions", checked: persistence)
        check.target = self
        check.action = #selector(scrollPersistenceChanged(_:))
        scrollPersistenceCheck = check
        addView(check, 22)
        addSpacing(16)

        let mcpSection = (configData["mcp_server"] as? [String: Any]) ?? [:]
        let mcpEnabled = (mcpSection["enabled"] as? Bool) ?? MCPServerConfiguration.default.enabled
        let mcpEnabledCheck = makeCheckbox("Enable local MCP server", checked: mcpEnabled)
        mcpEnabledCheck.target = self
        mcpEnabledCheck.action = #selector(mcpServerEnabledChanged(_:))
        mcpServerEnabledCheck = mcpEnabledCheck
        addView(mcpEnabledCheck, 22)
        addSpacing(12)

        let mcpPort = MCPServerConfiguration.normalizedPort(intVal(mcpSection["port"]) ?? MCPServerConfiguration.default.port)
        let (mcpPortRow, mcpPortField) = makeTextFieldRow(
            label: "MCP Port:",
            value: "\(mcpPort)",
            width: width
        )
        mcpPortField.identifier = NSUserInterfaceItemIdentifier("mcpServerPortField")
        mcpPortField.target = self
        mcpPortField.action = #selector(mcpServerPortChanged(_:))
        mcpPortField.isEnabled = mcpEnabled
        self.mcpServerPortField = mcpPortField
        addView(mcpPortRow, 28)
        addSpacing(4)
        addView(
            makeDescriptionLabel(
                "Local-only TCP MCP endpoint for LLM automation. Default: \(MCPServerConfiguration.defaultPort).",
                width: width
            ),
            28
        )
        addSpacing(20)

        let resetButton = NSButton(title: "Restore Defaults…", target: self, action: #selector(factoryResetClicked(_:)))
        resetButton.bezelStyle = .rounded
        resetButton.contentTintColor = NSColor.systemRed
        resetButton.identifier = NSUserInterfaceItemIdentifier("factoryResetButton")
        resetButton.frame = NSRect(x: 0, y: 0, width: 140, height: 28)
        factoryResetButton = resetButton
        addView(resetButton, 28)
        addSpacing(6)
        addView(
            makeDescriptionLabel(
                "Resets Settings-managed values to factory defaults while preserving workspaces and unknown config keys.",
                width: width
            ),
            32
        )
    }

    // MARK: - Section: Appearance

    private func buildAppearance(addView: (NSView, CGFloat) -> Void, addSpacing: (CGFloat) -> Void, width: CGFloat) {
        let font = configData["font"] as? [String: Any]
        let currentName = (font?["name"] as? String)
            ?? (configData["font_name"] as? String)
            ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular).fontName
        let currentSize = doubleVal(font?["size"])
            ?? doubleVal(configData["font_size"])
            ?? 11.0
        selectedFontName = currentName
        selectedFontSize = currentSize

        addView(makeSectionTitle("Appearance"), 28)
        addSpacing(12)

        // Font row
        let fontRow = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        let fLabel = makeLabel("Font:")
        fLabel.frame = NSRect(x: 0, y: 4, width: 120, height: 20)
        fontRow.addSubview(fLabel)

        let nameLabel = makeLabel("\(currentName) — \(Int(currentSize))pt")
        nameLabel.frame = NSRect(x: 124, y: 4, width: width - 204, height: 20)
        nameLabel.lineBreakMode = .byTruncatingTail
        fontRow.addSubview(nameLabel)
        fontNameLabel = nameLabel

        let chooseBtn = NSButton(title: "Select\u{2026}", target: self, action: #selector(chooseFontClicked(_:)))
        chooseBtn.bezelStyle = .rounded
        chooseBtn.frame = NSRect(x: width - 76, y: 0, width: 76, height: 28)
        fontRow.addSubview(chooseBtn)
        addView(fontRow, 28)
        addSpacing(12)

        // Font size row
        let sizeRow = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        let sLabel = makeLabel("Font Size:")
        sLabel.frame = NSRect(x: 0, y: 4, width: 120, height: 20)
        sizeRow.addSubview(sLabel)

        let sizeField = NSTextField()
        sizeField.stringValue = "\(Int(currentSize))"
        sizeField.isEditable = true
        sizeField.isBordered = true
        sizeField.backgroundColor = NSColor(calibratedWhite: 0.2, alpha: 1)
        sizeField.textColor = .white
        sizeField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        sizeField.frame = NSRect(x: 124, y: 2, width: 50, height: 24)
        sizeField.target = self
        sizeField.action = #selector(fontSizeFieldChanged(_:))
        sizeRow.addSubview(sizeField)
        fontSizeField = sizeField

        let stepper = NSStepper()
        stepper.minValue = 8
        stepper.maxValue = 72
        stepper.increment = 1
        stepper.integerValue = Int(currentSize)
        stepper.target = self
        stepper.action = #selector(fontSizeStepperChanged(_:))
        stepper.frame = NSRect(x: 180, y: 2, width: 19, height: 24)
        sizeRow.addSubview(stepper)
        fontSizeStepper = stepper

        let ptHint = makeLabel("pt (8–72)")
        ptHint.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)
        ptHint.frame = NSRect(x: 206, y: 4, width: 80, height: 20)
        sizeRow.addSubview(ptHint)
        addView(sizeRow, 28)
        addSpacing(16)

        let appearance = (configData["appearance"] as? [String: Any]) ?? [:]
        let foreground = RGBColor(
            hexString: (appearance["terminal_foreground_color"] as? String) ?? RGBColor.defaultTerminalForeground.hexString
        ) ?? .defaultTerminalForeground
        let background = RGBColor(
            hexString: (appearance["terminal_background_color"] as? String) ?? RGBColor.defaultTerminalBackground.hexString
        ) ?? .defaultTerminalBackground
        let opacity = min(
            1.0,
            max(0.0, doubleVal(appearance["terminal_background_opacity"]) ?? TerminalAppearanceConfiguration.default.backgroundOpacity)
        )

        let (foregroundRow, foregroundWell, foregroundHexLabel) = makeColorWellRow(
            label: "Terminal Foreground:",
            color: nsColor(for: foreground),
            hexValue: foreground.hexString,
            width: width
        )
        foregroundWell.identifier = NSUserInterfaceItemIdentifier("terminalForegroundColorWell")
        foregroundWell.target = self
        foregroundWell.action = #selector(terminalForegroundColorChanged(_:))
        terminalForegroundWell = foregroundWell
        terminalForegroundHexLabel = foregroundHexLabel
        addView(foregroundRow, 28)
        addSpacing(12)

        let (backgroundRow, backgroundWell, backgroundHexLabel) = makeColorWellRow(
            label: "Terminal Background:",
            color: nsColor(for: background),
            hexValue: background.hexString,
            width: width
        )
        backgroundWell.identifier = NSUserInterfaceItemIdentifier("terminalBackgroundColorWell")
        backgroundWell.target = self
        backgroundWell.action = #selector(terminalBackgroundColorChanged(_:))
        terminalBackgroundWell = backgroundWell
        terminalBackgroundHexLabel = backgroundHexLabel
        addView(backgroundRow, 28)
        addSpacing(12)

        let (opacityRow, opacitySlider, opacityValueLabel) = makeSliderRow(
            label: "Background Opacity:",
            value: opacity,
            width: width
        )
        opacitySlider.identifier = NSUserInterfaceItemIdentifier("terminalBackgroundOpacitySlider")
        opacitySlider.target = self
        opacitySlider.action = #selector(terminalBackgroundOpacityChanged(_:))
        terminalBackgroundOpacitySlider = opacitySlider
        terminalBackgroundOpacityValueLabel = opacityValueLabel
        terminalBackgroundOpacityValueLabel?.stringValue = opacityPercentString(opacity)
        addView(opacityRow, 28)
        addSpacing(8)
        addView(
            makeDescriptionLabel(
                "Lower opacity softens the terminal background. Integrated view may still use the macOS window material.",
                width: width
            ),
            18
        )
    }

    // MARK: - Section: Memory

    private func buildMemory(addView: (NSView, CGFloat) -> Void, addSpacing: (CGFloat) -> Void, width: CGFloat) {
        addView(makeSectionTitle("Memory"), 28)
        addSpacing(8)
        addView(makeDescriptionLabel("Memory settings apply to newly created terminals only.", width: width), 18)
        addSpacing(12)

        let currentMax = intVal(configData["memory_max"]) ?? (64 * 1024 * 1024)
        let currentInitial = intVal(configData["memory_initial"]) ?? (4 * 1024 * 1024)

        let (maxRow, maxField) = makeTextFieldRow(label: "Max Scrollback (MB):",
                                                   value: "\(currentMax / (1024 * 1024))", width: width)
        maxField.target = self
        maxField.action = #selector(memoryChanged(_:))
        memoryMaxField = maxField
        addView(maxRow, 28)
        addSpacing(12)

        let (initRow, initField) = makeTextFieldRow(label: "Initial Scrollback (MB):",
                                                     value: "\(currentInitial / (1024 * 1024))", width: width)
        initField.target = self
        initField.action = #selector(memoryChanged(_:))
        memoryInitialField = initField
        addView(initRow, 28)
        addSpacing(8)
        addView(makeDescriptionLabel("Minimum: 1 MB. Initial must not exceed max.", width: width), 18)
    }

    // MARK: - Section: Security

    private func buildSecurity(addView: (NSView, CGFloat) -> Void, addSpacing: (CGFloat) -> Void, width: CGFloat) {
        addView(makeSectionTitle("Security"), 28)
        addSpacing(12)

        let sec = configData["security"] as? [String: Any]

        let osc52 = makeCheckbox("Allow OSC 52 clipboard read",
                                 checked: (sec?["osc52_clipboard_read"] as? Bool) ?? false)
        osc52.target = self
        osc52.action = #selector(securityChanged(_:))
        osc52Check = osc52
        addView(osc52, 22)
        addSpacing(2)
        addView(makeDescriptionLabel("Allow terminal programs to read clipboard contents via escape sequences.", width: width), 16)
        addSpacing(12)

        let paste = makeCheckbox("Paste confirmation for multiline text",
                                 checked: (sec?["paste_confirmation"] as? Bool) ?? true)
        paste.target = self
        paste.action = #selector(securityChanged(_:))
        pasteConfirmCheck = paste
        addView(paste, 22)
        addSpacing(2)
        addView(makeDescriptionLabel("Show a confirmation dialog before pasting multiline content.", width: width), 16)
        addSpacing(12)

        let mouse = makeCheckbox("Restrict mouse reporting to alternate screen",
                                 checked: (sec?["mouse_report_restrict_alternate_screen"] as? Bool) ?? true)
        mouse.target = self
        mouse.action = #selector(securityChanged(_:))
        mouseRestrictCheck = mouse
        addView(mouse, 22)
        addSpacing(2)
        addView(makeDescriptionLabel("Only report mouse events when the terminal is in alternate screen mode.", width: width), 16)
        addSpacing(12)

        let winResize = makeCheckbox("Allow window resize sequences",
                                     checked: (sec?["allow_window_resize_sequence"] as? Bool) ?? false)
        winResize.target = self
        winResize.action = #selector(securityChanged(_:))
        windowResizeCheck = winResize
        addView(winResize, 22)
        addSpacing(2)
        addView(makeDescriptionLabel("Allow terminal programs to resize the window via escape sequences.", width: width), 16)
    }

    // MARK: - Section: Audit

    private func buildAudit(addView: (NSView, CGFloat) -> Void, addSpacing: (CGFloat) -> Void, width: CGFloat) {
        addView(makeSectionTitle("Audit"), 28)
        addSpacing(12)

        let audit = configData["audit"] as? [String: Any]
        let enabled = (audit?["enabled"] as? Bool) ?? false

        let enableCheck = makeCheckbox("Enable audit logging", checked: enabled)
        enableCheck.target = self
        enableCheck.action = #selector(auditEnabledChanged(_:))
        auditEnabledCheck = enableCheck
        addView(enableCheck, 22)
        addSpacing(12)

        let retentionDays = audit?["retention_days"] as? Int
        let (retRow, retField) = makeTextFieldRow(label: "Retention (days):",
                                                   value: retentionDays.map { "\($0)" } ?? "30", width: width)
        retField.isEnabled = enabled
        retField.target = self
        retField.action = #selector(auditChanged(_:))
        retentionField = retField
        addView(retRow, 28)
        addSpacing(2)
        addView(makeDescriptionLabel("Leave empty to keep logs indefinitely.", width: width), 16)
        addSpacing(12)

        let encrypt = makeCheckbox("Encrypt audit logs",
                                   checked: (audit?["encryption"] as? Bool) ?? false)
        encrypt.isEnabled = enabled
        encrypt.target = self
        encrypt.action = #selector(auditChanged(_:))
        encryptCheck = encrypt
        addView(encrypt, 22)
    }

    // MARK: - Actions

    @objc private func termChanged(_ sender: NSPopUpButton) {
        configData["term"] = sender.titleOfSelectedItem
        commitConfigChange()
    }

    @objc private func encodingChanged(_ sender: NSPopUpButton) {
        let map = ["UTF-8": "utf-8", "UTF-16": "utf-16", "UTF-16LE": "utf-16le", "UTF-16BE": "utf-16be"]
        configData["text_encoding"] = map[sender.titleOfSelectedItem ?? "UTF-8"] ?? "utf-8"
        commitConfigChange()
    }

    @objc private func outputConfirmedInputAnimationChanged(_ sender: NSButton) {
        var textInteraction = (configData["text_interaction"] as? [String: Any]) ?? [:]
        textInteraction["output_confirmed_input_animation"] = (sender.state == .on)
        configData["text_interaction"] = textInteraction
        commitConfigChange()
    }

    @objc private func typewriterSoundChanged(_ sender: NSButton) {
        var textInteraction = (configData["text_interaction"] as? [String: Any]) ?? [:]
        textInteraction["typewriter_sound_enabled"] = (sender.state == .on)
        configData["text_interaction"] = textInteraction
        commitConfigChange()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field.identifier?.rawValue == "launchShellPathField" else { return }
        let row = field.tag
        guard launchShellsValues.indices.contains(row) else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            launchShellsValues.remove(at: row)
        } else {
            launchShellsValues[row] = value
        }
        persistLaunchShells()
        launchShellsTableView?.reloadData()
    }

    @objc private func scrollPersistenceChanged(_ sender: NSButton) {
        var session = (configData["session"] as? [String: Any]) ?? [:]
        session["scroll_buffer_persistence"] = (sender.state == .on)
        configData["session"] = session
        commitConfigChange()
    }

    @objc private func mcpServerEnabledChanged(_ sender: NSButton) {
        var mcpServer = (configData["mcp_server"] as? [String: Any]) ?? [:]
        let enabled = (sender.state == .on)
        mcpServer["enabled"] = enabled
        mcpServer["port"] = MCPServerConfiguration.normalizedPort(
            Int(mcpServerPortField?.stringValue ?? "") ?? intVal(mcpServer["port"]) ?? MCPServerConfiguration.default.port
        )
        configData["mcp_server"] = mcpServer
        mcpServerPortField?.isEnabled = enabled
        commitConfigChange()
    }

    @objc private func mcpServerPortChanged(_ sender: NSTextField) {
        let normalizedPort = MCPServerConfiguration.normalizedPort(Int(sender.stringValue))
        sender.stringValue = "\(normalizedPort)"
        var mcpServer = (configData["mcp_server"] as? [String: Any]) ?? [:]
        mcpServer["enabled"] = (mcpServerEnabledCheck?.state == .on)
        mcpServer["port"] = normalizedPort
        configData["mcp_server"] = mcpServer
        commitConfigChange()
    }

    @objc private func chooseFontClicked(_ sender: NSButton) {
        let fontManager = NSFontManager.shared
        fontManager.target = self
        fontManager.action = #selector(fontPanelChanged(_:))
        let currentFont = NSFont(name: selectedFontName ?? "", size: CGFloat(selectedFontSize ?? 11))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(selectedFontSize ?? 11), weight: .regular)
        fontManager.setSelectedFont(currentFont, isMultiple: false)
        fontManager.orderFrontFontPanel(self)
    }

    @objc private func fontPanelChanged(_ sender: NSFontManager) {
        let currentFont = NSFont(name: selectedFontName ?? "", size: CGFloat(selectedFontSize ?? 11))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(selectedFontSize ?? 11), weight: .regular)
        let newFont = sender.convert(currentFont)
        selectedFontName = newFont.fontName
        selectedFontSize = Double(newFont.pointSize)
        fontNameLabel?.stringValue = "\(newFont.fontName) — \(Int(newFont.pointSize))pt"
        fontSizeField?.stringValue = "\(Int(newFont.pointSize))"
        fontSizeStepper?.integerValue = Int(newFont.pointSize)
        saveFontSettings()
    }

    @objc private func fontSizeStepperChanged(_ sender: NSStepper) {
        let size = sender.integerValue
        fontSizeField?.stringValue = "\(size)"
        selectedFontSize = Double(size)
        fontNameLabel?.stringValue = "\(selectedFontName ?? "System") — \(size)pt"
        saveFontSettings()
    }

    @objc private func fontSizeFieldChanged(_ sender: NSTextField) {
        guard let size = Int(sender.stringValue), size >= 8, size <= 72 else { return }
        fontSizeStepper?.integerValue = size
        selectedFontSize = Double(size)
        fontNameLabel?.stringValue = "\(selectedFontName ?? "System") — \(size)pt"
        saveFontSettings()
    }

    private func saveFontSettings() {
        var font = (configData["font"] as? [String: Any]) ?? [:]
        font["name"] = selectedFontName
        font["size"] = selectedFontSize.map { Int($0) }
        configData["font"] = font
        configData.removeValue(forKey: "font_name")
        configData.removeValue(forKey: "font_size")
        commitConfigChange()
    }

    @objc private func terminalForegroundColorChanged(_ sender: NSColorWell) {
        saveTerminalAppearance(
            foreground: rgbColor(from: sender.color),
            background: nil,
            opacity: nil
        )
    }

    @objc private func terminalBackgroundColorChanged(_ sender: NSColorWell) {
        saveTerminalAppearance(
            foreground: nil,
            background: rgbColor(from: sender.color),
            opacity: nil
        )
    }

    @objc private func terminalBackgroundOpacityChanged(_ sender: NSSlider) {
        let opacity = min(1.0, max(0.0, sender.doubleValue))
        terminalBackgroundOpacityValueLabel?.stringValue = opacityPercentString(opacity)
        saveTerminalAppearance(
            foreground: nil,
            background: nil,
            opacity: opacity
        )
    }

    private func saveTerminalAppearance(
        foreground: RGBColor?,
        background: RGBColor?,
        opacity: Double?
    ) {
        var appearance = (configData["appearance"] as? [String: Any]) ?? [:]
        let effectiveForeground = foreground ??
            RGBColor(hexString: appearance["terminal_foreground_color"] as? String ?? "") ??
            .defaultTerminalForeground
        let effectiveBackground = background ??
            RGBColor(hexString: appearance["terminal_background_color"] as? String ?? "") ??
            .defaultTerminalBackground
        let effectiveOpacity = min(
            1.0,
            max(
                0.0,
                opacity ?? doubleVal(appearance["terminal_background_opacity"]) ?? TerminalAppearanceConfiguration.default.backgroundOpacity
            )
        )

        appearance["terminal_foreground_color"] = effectiveForeground.hexString
        appearance["terminal_background_color"] = effectiveBackground.hexString
        appearance["terminal_background_opacity"] = effectiveOpacity
        configData["appearance"] = appearance

        terminalForegroundHexLabel?.stringValue = effectiveForeground.hexString
        terminalBackgroundHexLabel?.stringValue = effectiveBackground.hexString
        terminalBackgroundOpacityValueLabel?.stringValue = opacityPercentString(effectiveOpacity)

        commitConfigChange()
    }

    @objc private func memoryChanged(_ sender: NSTextField) {
        guard let maxMB = Int(memoryMaxField?.stringValue ?? ""),
              let initMB = Int(memoryInitialField?.stringValue ?? "") else { return }
        let maxBytes = max(1, maxMB) * 1024 * 1024
        let initBytes = min(maxBytes, max(1, initMB) * 1024 * 1024)
        configData["memory_max"] = maxBytes
        configData["memory_initial"] = initBytes
        commitConfigChange()
    }

    @objc private func securityChanged(_ sender: NSButton) {
        var sec = (configData["security"] as? [String: Any]) ?? [:]
        sec["osc52_clipboard_read"] = (osc52Check?.state == .on)
        sec["paste_confirmation"] = (pasteConfirmCheck?.state == .on)
        sec["mouse_report_restrict_alternate_screen"] = (mouseRestrictCheck?.state == .on)
       sec["allow_window_resize_sequence"] = (windowResizeCheck?.state == .on)
        configData["security"] = sec
        commitConfigChange()
    }

    @objc private func auditEnabledChanged(_ sender: NSButton) {
        let enabled = (sender.state == .on)
        retentionField?.isEnabled = enabled
        encryptCheck?.isEnabled = enabled
        auditChanged(sender)
    }

    @objc private func auditChanged(_ sender: Any) {
        var audit = (configData["audit"] as? [String: Any]) ?? [:]
        audit["enabled"] = (auditEnabledCheck?.state == .on)
        if let days = Int(retentionField?.stringValue ?? "") {
            audit["retention_days"] = days
        } else {
            audit.removeValue(forKey: "retention_days")
        }
        audit["encryption"] = (encryptCheck?.state == .on)
        configData["audit"] = audit
        commitConfigChange()
    }

    @objc private func factoryResetClicked(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Restore factory defaults?"
        alert.informativeText = "This resets Settings-managed values to their defaults and keeps workspaces and unknown config keys."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        if alert.runModal() == .alertFirstButtonReturn {
            resetToFactoryDefaults()
        }
    }

    // MARK: - UI Factories

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        label.font = .systemFont(ofSize: 13)
        label.sizeToFit()
        return label
    }

    private func makeSectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 18)
        label.textColor = .white
        label.sizeToFit()
        return label
    }

    private func makeDescriptionLabel(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)
        label.font = .systemFont(ofSize: 11)
        label.frame.size.width = width
        label.sizeToFit()
        return label
    }

    private func makeCheckbox(_ title: String, checked: Bool) -> NSButton {
        let check = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        check.state = checked ? .on : .off
        check.font = .systemFont(ofSize: 13)
        check.sizeToFit()
        return check
    }

    private func makePopupRow(label: String, values: [String], current: String,
                               width: CGFloat) -> (NSView, NSPopUpButton) {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        let l = makeLabel(label)
        l.frame = NSRect(x: 0, y: 4, width: settingsLabelColumnWidth, height: 20)
        row.addSubview(l)

        let popupX = settingsLabelColumnWidth + settingsControlSpacing
        let popupWidth = max(160, min(220, width - popupX))
        let popup = NSPopUpButton(frame: NSRect(x: popupX, y: 0, width: popupWidth, height: 28))
        popup.addItems(withTitles: values)
        popup.selectItem(withTitle: current)
        row.addSubview(popup)
        return (row, popup)
    }

    private func makeLaunchShellsEditor(width: CGFloat) -> NSView {
        let buttonSize = NSSize(width: 28, height: 28)
        let buttonSpacing: CGFloat = 4
        let buttonRowHeight = buttonSize.height
        let listHeight: CGFloat = 100
        let gapBetweenTableAndButtons: CGFloat = 6
        let containerHeight = listHeight + gapBetweenTableAndButtons + buttonRowHeight
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: containerHeight))

        // Label aligned to the top of the table
        let label = makeLabel("Launch Shells:")
        let labelY = containerHeight - 20
        label.frame = NSRect(x: 0, y: labelY, width: settingsLabelColumnWidth, height: 20)
        container.addSubview(label)

        let tableX = settingsLabelColumnWidth + settingsControlSpacing
        let tableWidth = width - tableX
        let tableY = buttonRowHeight + gapBetweenTableAndButtons

        let scrollView = NSScrollView(frame: NSRect(x: tableX, y: tableY, width: tableWidth, height: listHeight))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let tableView = NSTableView(frame: scrollView.bounds)
        tableView.identifier = NSUserInterfaceItemIdentifier("launchShellsTable")
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.width = tableWidth - 4
        tableView.addTableColumn(column)
        scrollView.documentView = tableView
        launchShellsTableView = tableView
        container.addSubview(scrollView)

        // Buttons in a horizontal row below the table
        let buttonConfigs: [(tooltip: String, symbol: String, action: Selector, identifier: String)] = [
            ("Add shell", "plus", #selector(addLaunchShellRow(_:)), "launchShellAddButton"),
            ("Remove selected shell", "minus", #selector(removeLaunchShellRow(_:)), "launchShellRemoveButton"),
            ("Move selected shell up", "arrow.up", #selector(moveLaunchShellRowUp(_:)), "launchShellUpButton"),
            ("Move selected shell down", "arrow.down", #selector(moveLaunchShellRowDown(_:)), "launchShellDownButton"),
        ]

        var currentX = tableX
        for buttonConfig in buttonConfigs {
            let button = NSButton(title: "", target: self, action: buttonConfig.action)
            button.identifier = NSUserInterfaceItemIdentifier(buttonConfig.identifier)
            button.bezelStyle = .rounded
            button.toolTip = buttonConfig.tooltip
            button.frame = NSRect(x: currentX, y: 0, width: buttonSize.width, height: buttonSize.height)
            configureLaunchShellButton(button, symbolName: buttonConfig.symbol)
            container.addSubview(button)
            currentX += buttonSize.width + buttonSpacing
        }

        // Reset button as a text button
        let resetButton = NSButton(title: "Reset to Default", target: self, action: #selector(resetLaunchShellRows(_:)))
        resetButton.identifier = NSUserInterfaceItemIdentifier("launchShellResetButton")
        resetButton.bezelStyle = .rounded
        resetButton.toolTip = "Restore default shell order"
        resetButton.font = NSFont.systemFont(ofSize: 11)
        resetButton.sizeToFit()
        resetButton.frame = NSRect(x: currentX + buttonSpacing, y: 0, width: resetButton.frame.width, height: buttonSize.height)
        container.addSubview(resetButton)

        tableView.reloadData()
        if !launchShellsValues.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        return container
    }

    private func configureLaunchShellButton(_ button: NSButton, symbolName: String) {
        if #available(macOS 11.0, *) {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: button.title)
            button.imagePosition = .imageOnly
        }
    }

    private func makeColorWellRow(
        label: String,
        color: NSColor,
        hexValue: String,
        width: CGFloat
    ) -> (NSView, NSColorWell, NSTextField) {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        let labelView = makeLabel(label)
        labelView.frame = NSRect(x: 0, y: 4, width: settingsLabelColumnWidth, height: 20)
        row.addSubview(labelView)

        let controlX = settingsLabelColumnWidth + settingsControlSpacing
        let well = NSColorWell(frame: NSRect(x: controlX, y: 2, width: 44, height: 24))
        well.color = color
        row.addSubview(well)

        let hexLabel = makeLabel(hexValue)
        hexLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hexLabel.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        let hexX = controlX + 44 + settingsControlSpacing
        hexLabel.frame = NSRect(x: hexX, y: 4, width: max(80, width - hexX), height: 20)
        row.addSubview(hexLabel)

        return (row, well, hexLabel)
    }

    private func makeSliderRow(
        label: String,
        value: Double,
        width: CGFloat
    ) -> (NSView, NSSlider, NSTextField) {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        let labelView = makeLabel(label)
        labelView.frame = NSRect(x: 0, y: 4, width: settingsLabelColumnWidth, height: 20)
        row.addSubview(labelView)

        let valueLabelWidth: CGFloat = 50
        let sliderX = settingsLabelColumnWidth + settingsControlSpacing
        let valueLabelX = width - valueLabelWidth
        let sliderWidth = max(120, valueLabelX - sliderX - settingsControlSpacing)
        let slider = NSSlider(value: value, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
        slider.numberOfTickMarks = 11
        slider.allowsTickMarkValuesOnly = false
        slider.frame = NSRect(x: sliderX, y: 2, width: sliderWidth, height: 24)
        row.addSubview(slider)

        let valueLabel = makeLabel(opacityPercentString(value))
        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: valueLabelX, y: 4, width: valueLabelWidth, height: 20)
        row.addSubview(valueLabel)

        return (row, slider, valueLabel)
    }

    private func makeTextFieldRow(label: String, value: String, width: CGFloat) -> (NSView, NSTextField) {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        let l = makeLabel(label)
        l.frame = NSRect(x: 0, y: 4, width: settingsLabelColumnWidth, height: 20)
        row.addSubview(l)

        let field = NSTextField()
        field.stringValue = value
        field.isEditable = true
        field.isBordered = true
        field.backgroundColor = NSColor(calibratedWhite: 0.2, alpha: 1)
        field.textColor = .white
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.frame = NSRect(x: settingsLabelColumnWidth + settingsControlSpacing, y: 2, width: 80, height: 24)
        row.addSubview(field)
        return (row, field)
    }

    // MARK: - Config value helpers

    private func stringValue(_ key: String) -> String? {
        configData[key] as? String
    }

    private func configuredLaunchShells() -> [String] {
        let shells = configData["shells"] as? [String: Any]
        let rawValues = shells?["launch_order"] as? [String] ?? ShellLaunchConfiguration.default.launchOrder
        return ShellLaunchConfiguration.normalizedLaunchOrder(rawValues)
    }

    private func persistLaunchShells() {
        let normalized = ShellLaunchConfiguration.normalizedLaunchOrder(launchShellsValues)
        launchShellsValues = normalized
        var shells = (configData["shells"] as? [String: Any]) ?? [:]
        shells["launch_order"] = normalized
        configData["shells"] = shells
        commitConfigChange()
    }

    @objc private func addLaunchShellRow(_ sender: NSButton) {
        launchShellsValues.append("")
        let newRow = launchShellsValues.count - 1
        launchShellsTableView?.reloadData()
        launchShellsTableView?.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
        launchShellsTableView?.editColumn(0, row: newRow, with: nil, select: true)
    }

    @objc private func removeLaunchShellRow(_ sender: NSButton) {
        guard let tableView = launchShellsTableView else { return }
        let row = tableView.selectedRow
        guard launchShellsValues.indices.contains(row) else { return }
        launchShellsValues.remove(at: row)
        persistLaunchShells()
        tableView.reloadData()
        let nextRow = min(row, max(launchShellsValues.count - 1, 0))
        if !launchShellsValues.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
        }
    }

    @objc private func moveLaunchShellRowUp(_ sender: NSButton) {
        guard let tableView = launchShellsTableView else { return }
        let row = tableView.selectedRow
        guard row > 0, launchShellsValues.indices.contains(row) else { return }
        launchShellsValues.swapAt(row, row - 1)
        persistLaunchShells()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: row - 1), byExtendingSelection: false)
    }

    @objc private func moveLaunchShellRowDown(_ sender: NSButton) {
        guard let tableView = launchShellsTableView else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < launchShellsValues.count - 1 else { return }
        launchShellsValues.swapAt(row, row + 1)
        persistLaunchShells()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
    }

    @objc private func resetLaunchShellRows(_ sender: NSButton) {
        launchShellsValues = ShellLaunchConfiguration.default.launchOrder
        persistLaunchShells()
        launchShellsTableView?.reloadData()
        launchShellsTableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    private func doubleVal(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        return value as? Double
    }

    private func intVal(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        return value as? Int
    }

    private func nsColor(for color: RGBColor) -> NSColor {
        NSColor(
            calibratedRed: CGFloat(color.red) / 255.0,
            green: CGFloat(color.green) / 255.0,
            blue: CGFloat(color.blue) / 255.0,
            alpha: 1.0
        )
    }

    private func rgbColor(from color: NSColor) -> RGBColor {
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        return RGBColor(
            red: UInt8((max(0.0, min(1.0, converted.redComponent)) * 255.0).rounded()),
            green: UInt8((max(0.0, min(1.0, converted.greenComponent)) * 255.0).rounded()),
            blue: UInt8((max(0.0, min(1.0, converted.blueComponent)) * 255.0).rounded())
        )
    }

    private func opacityPercentString(_ value: Double) -> String {
        "\(Int((value * 100.0).rounded()))%"
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView.identifier?.rawValue == "launchShellsTable" {
            return launchShellsValues.count
        }
        return Section.allCases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView.identifier?.rawValue == "launchShellsTable" {
            let cellIdentifier = NSUserInterfaceItemIdentifier("LaunchShellCell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 24))
                cell.identifier = cellIdentifier

                let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 24))
                textField.identifier = NSUserInterfaceItemIdentifier("launchShellPathField")
                textField.isEditable = true
                textField.isBordered = false
                textField.drawsBackground = false
                textField.backgroundColor = .clear
                textField.textColor = .white
                textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                textField.delegate = self
                cell.addSubview(textField)
                cell.textField = textField
            }

            cell.textField?.tag = row
            cell.textField?.stringValue = launchShellsValues[row]
            return cell
        }

        guard let section = Section(rawValue: row) else { return nil }

        let cellIdentifier = NSUserInterfaceItemIdentifier("SectionCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: 32))
            cell.identifier = cellIdentifier

            let imageView = NSImageView(frame: NSRect(x: 12, y: 7, width: 18, height: 18))
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.frame = NSRect(x: 38, y: 7, width: sidebarWidth - 50, height: 18)
            textField.font = .systemFont(ofSize: 13)
            textField.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
            cell.addSubview(textField)
            cell.textField = textField
        }

        cell.textField?.stringValue = section.title
        if #available(macOS 11.0, *) {
            cell.imageView?.image = NSImage(systemSymbolName: section.iconName,
                                            accessibilityDescription: section.title)
            cell.imageView?.contentTintColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let tableView = notification.object as? NSTableView,
           tableView.identifier?.rawValue == "launchShellsTable" {
            return
        }
        let row = sidebarTableView.selectedRow
        guard row >= 0, let section = Section(rawValue: row) else { return }
        showContentForSection(section)
    }
}

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

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
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
    var onClose: (() -> Void)?

    // Control references
    private var termPopup: NSPopUpButton?
    private var encodingPopup: NSPopUpButton?
    private var scrollPersistenceCheck: NSButton?
    private var fontNameLabel: NSTextField?
    private var fontSizeStepper: NSStepper?
    private var fontSizeField: NSTextField?
    private var selectedFontName: String?
    private var selectedFontSize: Double?
    private var memoryMaxField: NSTextField?
    private var memoryInitialField: NSTextField?
    private var osc52Check: NSButton?
    private var pasteConfirmCheck: NSButton?
    private var mouseRestrictCheck: NSButton?
    private var windowResizeCheck: NSButton?
    private var auditEnabledCheck: NSButton?
    private var retentionField: NSTextField?
    private var encryptCheck: NSButton?

    init() {
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
        let url = PtermDirectories.config
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            configData = [:]
            return
        }
        configData = json
    }

    private func saveConfigData() {
        guard let data = try? JSONSerialization.data(withJSONObject: configData,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? AtomicFileWriter.write(data, to: PtermDirectories.config, permissions: 0o600)
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
        addSpacing(16)

        let session = configData["session"] as? [String: Any]
        let persistence = (session?["scroll_buffer_persistence"] as? Bool) ?? false
        let check = makeCheckbox("Persist scroll buffer across sessions", checked: persistence)
        check.target = self
        check.action = #selector(scrollPersistenceChanged(_:))
        scrollPersistenceCheck = check
        addView(check, 22)
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
    }

    // MARK: - Section: Memory

    private func buildMemory(addView: (NSView, CGFloat) -> Void, addSpacing: (CGFloat) -> Void, width: CGFloat) {
        addView(makeSectionTitle("Memory"), 28)
        addSpacing(8)
        addView(makeDescriptionLabel("Memory settings apply to newly created terminals only.", width: width), 18)
        addSpacing(12)

        let currentMax = intVal(configData["memory_max"]) ?? (64 * 1024 * 1024)
        let currentInitial = intVal(configData["memory_initial"]) ?? (2 * 1024 * 1024)

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
        saveConfigData()
    }

    @objc private func encodingChanged(_ sender: NSPopUpButton) {
        let map = ["UTF-8": "utf-8", "UTF-16": "utf-16", "UTF-16LE": "utf-16le", "UTF-16BE": "utf-16be"]
        configData["text_encoding"] = map[sender.titleOfSelectedItem ?? "UTF-8"] ?? "utf-8"
        saveConfigData()
    }

    @objc private func scrollPersistenceChanged(_ sender: NSButton) {
        var session = (configData["session"] as? [String: Any]) ?? [:]
        session["scroll_buffer_persistence"] = (sender.state == .on)
        configData["session"] = session
        saveConfigData()
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
        saveConfigData()
    }

    @objc private func memoryChanged(_ sender: NSTextField) {
        guard let maxMB = Int(memoryMaxField?.stringValue ?? ""),
              let initMB = Int(memoryInitialField?.stringValue ?? "") else { return }
        let maxBytes = max(1, maxMB) * 1024 * 1024
        let initBytes = min(maxBytes, max(1, initMB) * 1024 * 1024)
        configData["memory_max"] = maxBytes
        configData["memory_initial"] = initBytes
        saveConfigData()
    }

    @objc private func securityChanged(_ sender: NSButton) {
        var sec = (configData["security"] as? [String: Any]) ?? [:]
        sec["osc52_clipboard_read"] = (osc52Check?.state == .on)
        sec["paste_confirmation"] = (pasteConfirmCheck?.state == .on)
        sec["mouse_report_restrict_alternate_screen"] = (mouseRestrictCheck?.state == .on)
        sec["allow_window_resize_sequence"] = (windowResizeCheck?.state == .on)
        configData["security"] = sec
        saveConfigData()
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
        saveConfigData()
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
        l.frame = NSRect(x: 0, y: 4, width: 120, height: 20)
        row.addSubview(l)

        let popup = NSPopUpButton(frame: NSRect(x: 124, y: 0, width: 200, height: 28))
        popup.addItems(withTitles: values)
        popup.selectItem(withTitle: current)
        row.addSubview(popup)
        return (row, popup)
    }

    private func makeTextFieldRow(label: String, value: String, width: CGFloat) -> (NSView, NSTextField) {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        let l = makeLabel(label)
        l.frame = NSRect(x: 0, y: 4, width: 160, height: 20)
        row.addSubview(l)

        let field = NSTextField()
        field.stringValue = value
        field.isEditable = true
        field.isBordered = true
        field.backgroundColor = NSColor(calibratedWhite: 0.2, alpha: 1)
        field.textColor = .white
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.frame = NSRect(x: 164, y: 2, width: 80, height: 24)
        row.addSubview(field)
        return (row, field)
    }

    // MARK: - Config value helpers

    private func stringValue(_ key: String) -> String? {
        configData[key] as? String
    }

    private func doubleVal(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        return value as? Double
    }

    private func intVal(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        return value as? Int
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
        let row = sidebarTableView.selectedRow
        guard row >= 0, let section = Section(rawValue: row) else { return }
        showContentForSection(section)
    }
}

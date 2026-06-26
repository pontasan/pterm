import AppKit

final class AIRoomManagerWindowController: NSWindowController, NSWindowDelegate {
    struct TerminalInfo: Equatable {
        let id: UUID
        let title: String
        let foregroundProcessName: String?
    }

    struct RoomInfo: Equatable {
        let id: String
        var name: String
        var terminalIDs: Set<UUID>
    }

    var onSaveRooms: (([RoomInfo]) -> Void)?
    var onRegeneratePassword: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onClose: (() -> Void)?

    private var password: String
    private var port: Int
    private var terminals: [TerminalInfo]
    private var rooms: [RoomInfo]
    private var selectedRoomIndex: Int? {
        didSet {
            terminalTableView.reloadData()
            updateRoomActionState()
        }
    }

    private let passwordField = NSTextField(labelWithString: "")
    private let portField = NSTextField(labelWithString: "")
    private let roomTableView = NSTableView()
    private let terminalTableView = NSTableView()
    private let deleteRoomButton = NSButton(title: "Delete Room", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    init(password: String, port: Int, terminals: [TerminalInfo], rooms: [RoomInfo]) {
        self.password = password
        self.port = port
        self.terminals = terminals
        self.rooms = rooms

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Room Manager"
        window.minSize = NSSize(width: 820, height: 520)
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContentView()
        window.center()
        if !rooms.isEmpty {
            selectedRoomIndex = 0
            roomTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateHeader()
        updateRoomActionState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh(password: String, port: Int, terminals: [TerminalInfo], rooms: [RoomInfo]) {
        self.password = password
        self.port = port
        self.terminals = terminals
        self.rooms = rooms
        if let selectedRoomIndex, selectedRoomIndex >= rooms.count {
            self.selectedRoomIndex = rooms.isEmpty ? nil : rooms.count - 1
        }
        updateHeader()
        roomTableView.reloadData()
        terminalTableView.reloadData()
        if let selectedRoomIndex {
            roomTableView.selectRowIndexes(IndexSet(integer: selectedRoomIndex), byExtendingSelection: false)
        }
        updateRoomActionState()
    }

    private func buildContentView() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let header = buildHeaderView()
        let roomPane = buildRoomPane()
        let terminalPane = buildTerminalPane()

        let contentStack = NSStackView(views: [roomPane, terminalPane])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .horizontal
        contentStack.spacing = 12
        contentStack.distribution = .fill

        let footer = buildFooterView()

        root.addSubview(header)
        root.addSubview(contentStack)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),

            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            contentStack.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            roomPane.widthAnchor.constraint(equalToConstant: 300),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            footer.heightAnchor.constraint(equalToConstant: 32)
        ])

        return root
    }

    private func buildHeaderView() -> NSView {
        let passwordLabel = NSTextField(labelWithString: "Password")
        passwordLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        passwordField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        passwordField.lineBreakMode = .byTruncatingMiddle
        passwordField.isSelectable = true

        let portLabel = NSTextField(labelWithString: "AI Room MCP Port")
        portLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let copyButton = NSButton(title: "Copy Password", target: self, action: #selector(copyPasswordClicked(_:)))
        copyButton.bezelStyle = .rounded

        let regenerateButton = NSButton(title: "Regenerate Password", target: self, action: #selector(regeneratePasswordClicked(_:)))
        regenerateButton.bezelStyle = .rounded

        let grid = NSGridView(views: [
            [passwordLabel, passwordField, copyButton, regenerateButton],
            [portLabel, portField, NSView(), NSView()]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).width = 140
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 520
        return grid
    }

    private func buildRoomPane() -> NSView {
        roomTableView.delegate = self
        roomTableView.dataSource = self
        roomTableView.headerView = nil
        roomTableView.usesAlternatingRowBackgroundColors = true
        roomTableView.allowsMultipleSelection = false
        roomTableView.addTableColumn(NSTableColumn(identifier: .roomNameColumn))

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = roomTableView

        let addRoomButton = NSButton(title: "Add Room", target: self, action: #selector(addRoomClicked(_:)))
        addRoomButton.bezelStyle = .rounded

        deleteRoomButton.target = self
        deleteRoomButton.action = #selector(deleteRoomClicked(_:))
        deleteRoomButton.bezelStyle = .rounded
        deleteRoomButton.contentTintColor = .systemRed

        let buttons = NSStackView(views: [addRoomButton, deleteRoomButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let title = NSTextField(labelWithString: "Rooms")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(title)
        pane.addSubview(scrollView)
        pane.addSubview(buttons)

        title.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            title.topAnchor.constraint(equalTo: pane.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),

            buttons.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            buttons.heightAnchor.constraint(equalToConstant: 30)
        ])
        return pane
    }

    private func buildTerminalPane() -> NSView {
        terminalTableView.delegate = self
        terminalTableView.dataSource = self
        terminalTableView.usesAlternatingRowBackgroundColors = true
        terminalTableView.allowsMultipleSelection = false
        addTerminalColumn(identifier: .terminalIncludedColumn, title: "", width: 44)
        addTerminalColumn(identifier: .terminalTitleColumn, title: "Title", width: 180)
        addTerminalColumn(identifier: .terminalProcessColumn, title: "Process", width: 120)
        addTerminalColumn(identifier: .terminalIDColumn, title: "PTERM_TERMINAL_ID", width: 300)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = terminalTableView

        let title = NSTextField(labelWithString: "Terminals")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(title)
        pane.addSubview(scrollView)
        title.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            title.topAnchor.constraint(equalTo: pane.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
        ])
        return pane
    }

    private func buildFooterView() -> NSView {
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked(_:)))
        refreshButton.bezelStyle = .rounded

        saveButton.target = self
        saveButton.action = #selector(saveClicked(_:))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [refreshButton, saveButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let root = NSStackView(views: [spacer, stack])
        root.translatesAutoresizingMaskIntoConstraints = false
        root.orientation = .horizontal
        root.alignment = .centerY
        return root
    }

    private func addTerminalColumn(identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = identifier == .terminalIncludedColumn ? width : 80
        terminalTableView.addTableColumn(column)
    }

    private func updateHeader() {
        passwordField.stringValue = password
        portField.stringValue = "\(port)"
    }

    private func updateRoomActionState() {
        deleteRoomButton.isEnabled = selectedRoomIndex != nil
        saveButton.isEnabled = true
    }

    @objc private func addRoomClicked(_ sender: Any?) {
        let room = RoomInfo(id: UUID().uuidString, name: "Room \(rooms.count + 1)", terminalIDs: [])
        rooms.append(room)
        let row = rooms.count - 1
        selectedRoomIndex = row
        roomTableView.reloadData()
        roomTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        terminalTableView.reloadData()
    }

    @objc private func deleteRoomClicked(_ sender: Any?) {
        guard let selectedRoomIndex else { return }
        rooms.remove(at: selectedRoomIndex)
        let nextIndex = rooms.isEmpty ? nil : min(selectedRoomIndex, rooms.count - 1)
        self.selectedRoomIndex = nextIndex
        roomTableView.reloadData()
        if let nextIndex {
            roomTableView.selectRowIndexes(IndexSet(integer: nextIndex), byExtendingSelection: false)
        }
        terminalTableView.reloadData()
        saveClicked(sender)
    }

    @objc private func saveClicked(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        normalizeRoomNames()
        onSaveRooms?(rooms)
    }

    @objc private func copyPasswordClicked(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
    }

    @objc private func regeneratePasswordClicked(_ sender: Any?) {
        onRegeneratePassword?()
    }

    @objc private func refreshClicked(_ sender: Any?) {
        onRefresh?()
    }

    @objc private func membershipCheckboxChanged(_ sender: NSButton) {
        guard let selectedRoomIndex else { return }
        let row = terminalTableView.row(for: sender)
        guard terminals.indices.contains(row) else { return }
        let terminalID = terminals[row].id
        if sender.state == .on {
            rooms[selectedRoomIndex].terminalIDs.insert(terminalID)
        } else {
            rooms[selectedRoomIndex].terminalIDs.remove(terminalID)
        }
    }

    private func normalizeRoomNames() {
        for index in rooms.indices {
            let trimmed = rooms[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            rooms[index].name = trimmed.isEmpty ? "Room" : trimmed
        }
        roomTableView.reloadData()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

extension AIRoomManagerWindowController: NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === roomTableView {
            return rooms.count
        }
        return terminals.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === roomTableView else { return }
        let row = roomTableView.selectedRow
        selectedRoomIndex = row >= 0 ? row : nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === roomTableView {
            guard rooms.indices.contains(row) else { return nil }
            let field = NSTextField()
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = true
            field.stringValue = rooms[row].name
            field.target = self
            field.action = #selector(roomNameCommitted(_:))
            field.delegate = self
            return field
        }

        guard terminals.indices.contains(row),
              let identifier = tableColumn?.identifier else {
            return nil
        }
        let terminal = terminals[row]
        switch identifier {
        case .terminalIncludedColumn:
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(membershipCheckboxChanged(_:)))
            checkbox.state = selectedRoomIndex.flatMap { rooms[$0].terminalIDs.contains(terminal.id) } == true ? .on : .off
            checkbox.isEnabled = selectedRoomIndex != nil
            return checkbox
        case .terminalTitleColumn:
            return tableLabel(terminal.title)
        case .terminalProcessColumn:
            return tableLabel(terminal.foregroundProcessName ?? "")
        case .terminalIDColumn:
            let label = tableLabel(terminal.id.uuidString)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.lineBreakMode = .byTruncatingMiddle
            return label
        default:
            return nil
        }
    }

    @objc private func roomNameCommitted(_ sender: NSTextField) {
        commitRoomName(from: sender)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field.superview === roomTableView || roomTableView.row(for: field) >= 0 else {
            return
        }
        commitRoomName(from: field)
    }

    private func commitRoomName(from sender: NSTextField) {
        let row = roomTableView.row(for: sender)
        guard rooms.indices.contains(row) else { return }
        let trimmed = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rooms[row].name = trimmed.isEmpty ? "Room" : trimmed
        sender.stringValue = rooms[row].name
    }

    private func tableLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.isSelectable = true
        return field
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let roomNameColumn = NSUserInterfaceItemIdentifier("AIRoomNameColumn")
    static let terminalIncludedColumn = NSUserInterfaceItemIdentifier("AIRoomTerminalIncludedColumn")
    static let terminalTitleColumn = NSUserInterfaceItemIdentifier("AIRoomTerminalTitleColumn")
    static let terminalProcessColumn = NSUserInterfaceItemIdentifier("AIRoomTerminalProcessColumn")
    static let terminalIDColumn = NSUserInterfaceItemIdentifier("AIRoomTerminalIDColumn")
}

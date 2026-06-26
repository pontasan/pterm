import AppKit

final class AIRoomChatPromptWindowController: NSWindowController, NSWindowDelegate {
    struct TerminalInfo: Equatable {
        let id: UUID
        let title: String
        let foregroundProcessName: String?
    }

    struct RoomInfo: Equatable {
        let id: String
        let name: String
        let terminalIDs: Set<UUID>
    }

    var onSend: ((UUID, String) -> Void)?
    var onClose: (() -> Void)?

    private let password: String
    private let port: Int
    private let sourceTerminalID: UUID
    private let terminals: [TerminalInfo]
    private let rooms: [RoomInfo]
    private let joinedRoomIndices: [Int]

    private let passwordField = NSTextField(labelWithString: "")
    private let portField = NSTextField(labelWithString: "")
    private let roomPopup = NSPopUpButton()
    private let terminalPopup = NSPopUpButton()
    private let promptTextView = NSTextView()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)

    init(
        password: String,
        port: Int,
        sourceTerminalID: UUID,
        terminals: [TerminalInfo],
        rooms: [RoomInfo]
    ) {
        self.password = password
        self.port = port
        self.sourceTerminalID = sourceTerminalID
        self.terminals = terminals
        self.rooms = rooms
        self.joinedRoomIndices = rooms.indices.filter { rooms[$0].terminalIDs.contains(sourceTerminalID) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Room Chat"
        window.minSize = NSSize(width: 640, height: 460)
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContentView()
        window.center()
        populateRooms()
        updateTerminalPopup(clearSelection: false)
        updateSendButtonState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContentView() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        passwordField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        passwordField.lineBreakMode = .byTruncatingMiddle
        passwordField.isSelectable = true
        passwordField.stringValue = password
        portField.stringValue = "\(port)"
        portField.isSelectable = true

        roomPopup.target = self
        roomPopup.action = #selector(roomChanged(_:))
        terminalPopup.target = self
        terminalPopup.action = #selector(terminalChanged(_:))

        promptTextView.font = .systemFont(ofSize: 13)
        promptTextView.isRichText = false
        promptTextView.allowsUndo = true
        promptTextView.delegate = self
        promptTextView.textColor = .textColor
        promptTextView.backgroundColor = NSColor.textBackgroundColor

        let promptScrollView = NSScrollView()
        promptScrollView.translatesAutoresizingMaskIntoConstraints = false
        promptScrollView.hasVerticalScroller = true
        promptScrollView.borderType = .bezelBorder
        promptScrollView.documentView = promptTextView

        sendButton.target = self
        sendButton.action = #selector(sendClicked(_:))
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1B}"

        let titleLabel = makeLabel("MCP Room Chat")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)

        let passwordLabel = makeLabel("Password")
        let portLabel = makeLabel("Port")
        let roomLabel = makeLabel("Room")
        let terminalLabel = makeLabel("Target Terminal")
        let promptLabel = makeLabel("Prompt")

        let form = NSGridView(views: [
            [passwordLabel, passwordField],
            [portLabel, portField],
            [roomLabel, roomPopup],
            [terminalLabel, terminalPopup]
        ])
        form.translatesAutoresizingMaskIntoConstraints = false
        form.rowSpacing = 10
        form.columnSpacing = 12
        form.column(at: 0).width = 120
        form.column(at: 1).xPlacement = .fill

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [footerSpacer, cancelButton, sendButton])
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        for view in [titleLabel, form, promptLabel, promptScrollView, footer] {
            root.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),

            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            form.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),

            promptLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            promptLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            promptLabel.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 16),

            promptScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            promptScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            promptScrollView.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 8),
            promptScrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            footer.heightAnchor.constraint(equalToConstant: 32)
        ])

        return root
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        return field
    }

    private func populateRooms() {
        roomPopup.removeAllItems()
        guard !joinedRoomIndices.isEmpty else {
            roomPopup.addItem(withTitle: "No joined rooms")
            roomPopup.lastItem?.isEnabled = false
            roomPopup.isEnabled = false
            return
        }

        roomPopup.isEnabled = true
        for roomIndex in joinedRoomIndices {
            let room = rooms[roomIndex]
            roomPopup.addItem(withTitle: room.name)
            roomPopup.lastItem?.representedObject = roomIndex
        }
        roomPopup.selectItem(at: 0)
    }

    private func selectedRoomIndex() -> Int? {
        roomPopup.selectedItem?.representedObject as? Int
    }

    private func targetTerminals(for room: RoomInfo) -> [TerminalInfo] {
        terminals
            .filter { $0.id != sourceTerminalID && room.terminalIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let left = terminalDisplayTitle(lhs)
                let right = terminalDisplayTitle(rhs)
                if left == right {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return left.localizedStandardCompare(right) == .orderedAscending
            }
    }

    private func updateTerminalPopup(clearSelection: Bool) {
        terminalPopup.removeAllItems()
        guard let roomIndex = selectedRoomIndex(), rooms.indices.contains(roomIndex) else {
            terminalPopup.addItem(withTitle: "No room selected")
            terminalPopup.lastItem?.isEnabled = false
            terminalPopup.isEnabled = false
            updateSendButtonState()
            return
        }

        let targets = targetTerminals(for: rooms[roomIndex])
        guard !targets.isEmpty else {
            terminalPopup.addItem(withTitle: "No target terminals in this room")
            terminalPopup.lastItem?.isEnabled = false
            terminalPopup.isEnabled = false
            updateSendButtonState()
            return
        }

        terminalPopup.isEnabled = true
        if clearSelection || targets.count > 1 {
            terminalPopup.addItem(withTitle: "Select a terminal...")
            terminalPopup.lastItem?.representedObject = nil
        }
        for terminal in targets {
            terminalPopup.addItem(withTitle: terminalDisplayTitle(terminal))
            terminalPopup.lastItem?.representedObject = terminal.id
        }
        if !clearSelection, targets.count == 1 {
            terminalPopup.selectItem(at: 0)
        } else {
            terminalPopup.selectItem(at: 0)
        }
        updateSendButtonState()
    }

    private func terminalDisplayTitle(_ terminal: TerminalInfo) -> String {
        let process = terminal.foregroundProcessName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let processText = process?.isEmpty == false ? process! : "unknown"
        return "\(terminal.title) (\(processText)) - \(terminal.id.uuidString)"
    }

    private func selectedTargetTerminalID() -> UUID? {
        terminalPopup.selectedItem?.representedObject as? UUID
    }

    private func promptText() -> String {
        promptTextView.string
    }

    private func updateSendButtonState() {
        sendButton.isEnabled = selectedTargetTerminalID() != nil
            && !promptText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func roomChanged(_ sender: Any?) {
        updateTerminalPopup(clearSelection: true)
    }

    @objc private func terminalChanged(_ sender: Any?) {
        updateSendButtonState()
    }

    @objc private func sendClicked(_ sender: Any?) {
        guard let targetID = selectedTargetTerminalID() else { return }
        let text = promptText()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSend?(targetID, text)
        close()
    }

    @objc private func cancelClicked(_ sender: Any?) {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

extension AIRoomChatPromptWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        updateSendButtonState()
    }
}

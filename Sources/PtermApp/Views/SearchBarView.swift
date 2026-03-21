import AppKit

final class SearchBarView: NSView, NSSearchFieldDelegate {
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "0")
    private let prevButton = NSButton()
    private let nextButton = NSButton()

    var onQueryChange: ((String) -> Void)?
    var onNavigateNext: (() -> Void)?
    var onNavigatePrevious: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.95).cgColor
        layer?.cornerRadius = 8

        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(submitSearch(_:))
        addSubview(searchField)

        prevButton.bezelStyle = .inline
        prevButton.isBordered = false
        prevButton.target = self
        prevButton.action = #selector(prevClicked(_:))
        prevButton.toolTip = "Previous match (Shift+Cmd+G)"
        if #available(macOS 11.0, *) {
            prevButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")
        } else {
            prevButton.title = "▲"
        }
        prevButton.contentTintColor = NSColor(calibratedWhite: 0.8, alpha: 1)
        addSubview(prevButton)

        nextButton.bezelStyle = .inline
        nextButton.isBordered = false
        nextButton.target = self
        nextButton.action = #selector(nextClicked(_:))
        nextButton.toolTip = "Next match (Cmd+G)"
        if #available(macOS 11.0, *) {
            nextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")
        } else {
            nextButton.title = "▼"
        }
        nextButton.contentTintColor = NSColor(calibratedWhite: 0.8, alpha: 1)
        addSubview(nextButton)

        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        addSubview(countLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        let buttonSize: CGFloat = 24
        let buttonSpacing: CGFloat = 2
        let labelWidth: CGFloat = 56

        // Right side: [count] [▲] [▼]
        let buttonsWidth = buttonSize * 2 + buttonSpacing
        let rightWidth = labelWidth + buttonsWidth + inset

        let nextX = bounds.width - inset - buttonSize
        let prevX = nextX - buttonSize - buttonSpacing
        let buttonY = (bounds.height - buttonSize) / 2

        nextButton.frame = NSRect(x: nextX, y: buttonY, width: buttonSize, height: buttonSize)
        prevButton.frame = NSRect(x: prevX, y: buttonY, width: buttonSize, height: buttonSize)

        countLabel.frame = NSRect(x: prevX - labelWidth - 4,
                                  y: 8,
                                  width: labelWidth,
                                  height: bounds.height - 16)

        searchField.frame = NSRect(x: inset,
                                   y: 6,
                                   width: bounds.width - rightWidth - inset * 2,
                                   height: bounds.height - 12)
    }

    func controlTextDidChange(_ obj: Notification) {
        onQueryChange?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    @objc private func submitSearch(_ sender: Any?) {
        onNavigateNext?()
    }

    @objc private func prevClicked(_ sender: Any?) {
        onNavigatePrevious?()
    }

    @objc private func nextClicked(_ sender: Any?) {
        onNavigateNext?()
    }

    func focus() {
        window?.makeFirstResponder(searchField)
    }

    func resetQuery() {
        searchField.stringValue = ""
    }

    func updateCount(current: Int?, total: Int) {
        if let current, total > 0 {
            countLabel.stringValue = "\(current)/\(total)"
        } else {
            countLabel.stringValue = "\(total)"
        }
    }
}

import AppKit

final class SearchBarView: NSView, NSSearchFieldDelegate {
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "0")

    var onQueryChange: ((String) -> Void)?
    var onNavigateNext: (() -> Void)?
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
        let labelWidth: CGFloat = 64
        countLabel.frame = NSRect(x: bounds.width - inset - labelWidth,
                                  y: 8,
                                  width: labelWidth,
                                  height: bounds.height - 16)
        searchField.frame = NSRect(x: inset,
                                   y: 6,
                                   width: bounds.width - labelWidth - inset * 3,
                                   height: bounds.height - 12)
    }

    func controlTextDidChange(_ obj: Notification) {
        onQueryChange?(searchField.stringValue)
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    @objc private func submitSearch(_ sender: Any?) {
        onNavigateNext?()
    }

    func focus() {
        window?.makeFirstResponder(searchField)
    }

    func updateCount(current: Int?, total: Int) {
        if let current, total > 0 {
            countLabel.stringValue = "\(current)/\(total)"
        } else {
            countLabel.stringValue = "\(total)"
        }
    }
}

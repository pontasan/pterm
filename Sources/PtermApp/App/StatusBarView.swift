import AppKit

final class StatusBarView: NSView {
    private let label = NSTextField(labelWithString: "-- MB")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor

        label.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.alignment = .left
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 12, dy: 4)
    }

    func updateMemoryUsage(bytes: UInt64) {
        let megabytes = Double(bytes) / (1024 * 1024)
        label.stringValue = String(format: "%.1f MB", megabytes)
    }
}

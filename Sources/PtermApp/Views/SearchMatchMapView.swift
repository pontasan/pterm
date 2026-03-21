import AppKit

/// A vertical minimap overlay that shows search match positions relative to the
/// full terminal content height, similar to VS Code's scrollbar match indicators.
///
/// Drawn as a translucent strip on the right edge of the terminal. Each match
/// is a small horizontal tick; the current match uses a brighter color.
/// A semi-transparent thumb indicates the currently visible viewport region.
final class SearchMatchMapView: NSView {
    struct State: Equatable {
        let totalRows: Int
        let viewportRows: Int
        let scrollOffset: Int
        let matches: [MatchPosition]
        let currentMatchIndex: Int?

        struct MatchPosition: Equatable {
            let absoluteRow: Int
        }

        static let empty = State(
            totalRows: 0,
            viewportRows: 0,
            scrollOffset: 0,
            matches: [],
            currentMatchIndex: nil
        )
    }

    private static let stripWidth: CGFloat = 10
    private static let matchTickHeight: CGFloat = 2
    private static let matchColor = NSColor(calibratedRed: 0.9, green: 0.6, blue: 0.1, alpha: 0.9)
    private static let currentMatchColor = NSColor(calibratedRed: 1.0, green: 0.3, blue: 0.2, alpha: 1.0)
    private static let thumbColor = NSColor(calibratedWhite: 0.7, alpha: 0.25)
    private static let thumbBorderColor = NSColor(calibratedWhite: 0.8, alpha: 0.4)
    private static let backgroundColor = NSColor(calibratedWhite: 0.0, alpha: 0.3)

    private var state: State = .empty

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func update(state newState: State) {
        guard state != newState else { return }
        state = newState
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard state.totalRows > 0, !state.matches.isEmpty else { return }

        let stripX = bounds.width - Self.stripWidth
        let stripRect = NSRect(x: stripX, y: 0, width: Self.stripWidth, height: bounds.height)

        // Background
        Self.backgroundColor.setFill()
        NSBezierPath(roundedRect: stripRect, xRadius: 3, yRadius: 3).fill()

        let usableHeight = bounds.height
        let totalRows = CGFloat(state.totalRows)

        // Viewport thumb
        let thumbTop = rowToY(state.totalRows - state.scrollOffset - state.viewportRows, totalRows: totalRows, height: usableHeight)
        let thumbBottom = rowToY(state.totalRows - state.scrollOffset, totalRows: totalRows, height: usableHeight)
        let thumbRect = NSRect(
            x: stripX,
            y: thumbTop,
            width: Self.stripWidth,
            height: max(4, thumbBottom - thumbTop)
        )
        Self.thumbColor.setFill()
        NSBezierPath(roundedRect: thumbRect, xRadius: 2, yRadius: 2).fill()
        Self.thumbBorderColor.setStroke()
        NSBezierPath(roundedRect: thumbRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()

        // Match ticks
        for (index, match) in state.matches.enumerated() {
            let y = rowToY(match.absoluteRow, totalRows: totalRows, height: usableHeight)
            let tickRect = NSRect(
                x: stripX + 1,
                y: y,
                width: Self.stripWidth - 2,
                height: Self.matchTickHeight
            )
            let isCurrent = state.currentMatchIndex == index
            let color = isCurrent ? Self.currentMatchColor : Self.matchColor
            color.setFill()
            tickRect.fill()
        }
    }

    private func rowToY(_ row: Int, totalRows: CGFloat, height: CGFloat) -> CGFloat {
        guard totalRows > 0 else { return 0 }
        return (CGFloat(row) / totalRows) * height
    }
}

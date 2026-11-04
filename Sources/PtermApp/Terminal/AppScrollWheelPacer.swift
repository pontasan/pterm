import Foundation

/// Feeds wheel notches to a full-screen application while a selection follows its text.
///
/// Following needs consecutive frames to share text, but applications coalesce queued wheel
/// events into one repaint and accelerate them, so an unpaced fling repaints a screen that
/// shares nothing with the previous one. Only one batch is outstanding at a time, and the size
/// of the next one comes from how far the last one really moved: how many rows a notch moves
/// is the application's choice and is not proportional to the number of notches.
struct AppScrollWheelPacer {
    /// Shortest wait for a repaint. A repaint that never comes means the application ignored
    /// the wheel, for example at the end of its text.
    private static let minimumResponseTimeout: TimeInterval = 0.05

    private static let maximumQueueDuration: TimeInterval = 0.2

    private(set) var isAwaitingRepaint = false
    private(set) var pendingCount = 0
    private(set) var button: Int?
    private var batchSize = 1
    private var averageLatency: TimeInterval?

    var responseTimeout: TimeInterval {
        max(Self.minimumResponseTimeout, (averageLatency ?? 0) * 4)
    }

    /// What can still be delivered within `maximumQueueDuration`. Beyond it the screen would
    /// keep moving noticeably after the user stopped, so a faster wheel does not queue more.
    private var maximumPendingCount: Int {
        // Until a repaint was measured, the first event of a gesture is all there is.
        guard let averageLatency, averageLatency > 0 else { return .max }
        return max(1, Int(Self.maximumQueueDuration / averageLatency)) * batchSize
    }

    /// Queues notches. Returns how many to send now.
    mutating func add(button: Int, count: Int) -> Int {
        // Scrolling the other way cancels what the old direction had not delivered yet.
        if button != self.button {
            self.button = button
            pendingCount = 0
            batchSize = 1
        }
        // How far the application moves depends on how fast the wheel has been turning, so
        // what was learned does not outlast the burst it was learned from.
        if !isAwaitingRepaint, pendingCount == 0 {
            batchSize = 1
        }
        pendingCount = min(pendingCount &+ count, maximumPendingCount)
        return isAwaitingRepaint ? 0 : takeBatch()
    }

    /// A repaint finished. Returns how many notches to send next.
    mutating func repaintSettled(rowsMoved: Int, movingRows: Int, latency: TimeInterval) -> Int {
        guard isAwaitingRepaint else { return 0 }
        // A repaint that moved nothing is unrelated to the wheel, such as a status line.
        guard rowsMoved > 0 else { return 0 }
        averageLatency = averageLatency.map { ($0 * 3 + latency) / 4 } ?? latency
        // Applications accelerate: measured on Claude Code, 4 notches move up to 30 rows where
        // 1 moves 6. Growing only up to a quarter of the moving rows keeps the next step inside
        // the screen even so, and beyond a half little text is left to align on.
        if rowsMoved * 4 <= movingRows {
            batchSize *= 2
        } else if rowsMoved * 2 > movingRows {
            batchSize = max(1, batchSize / 2)
        }
        isAwaitingRepaint = false
        return takeBatch()
    }

    /// No repaint came. Returns how many notches to send next.
    mutating func responseTimedOut() -> Int {
        guard isAwaitingRepaint else { return 0 }
        isAwaitingRepaint = false
        return takeBatch()
    }

    /// Empties the queue, for when pacing is no longer needed.
    mutating func takeAll() -> Int {
        defer {
            pendingCount = 0
            isAwaitingRepaint = false
        }
        return pendingCount
    }

    private mutating func takeBatch() -> Int {
        let batch = min(batchSize, pendingCount)
        pendingCount -= batch
        isAwaitingRepaint = batch > 0
        return batch
    }
}

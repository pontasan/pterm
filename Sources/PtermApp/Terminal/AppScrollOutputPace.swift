import Foundation

/// How long a pause in an application's output means that a repaint is finished.
///
/// The reads of one repaint arrive back to back on a local terminal, but over a slow link they
/// can be tens of milliseconds apart, and taking such a gap for the end of a repaint would store
/// half of a frame. So the pause is measured from the gaps seen between reads of this terminal.
/// Only gaps within a repaint count. A gap after a repaint is known to be over says how often the
/// application repaints, which has nothing to do with the link: taken for one, it would stretch
/// the pause until repaints run together and are never seen settled.
struct AppScrollOutputPace {
    /// One display frame at 60 Hz: no repaint is shown sooner, so nothing is gained by less.
    private static let minimumPause: TimeInterval = 1.0 / 60.0
    /// A longer gap separates repaints, and is not a gap within one.
    private static let maximumGapWithinRepaint: TimeInterval = 0.25
    private static let decayPerRead = 0.98

    private var lastReadUptime: TimeInterval?
    private var largestRecentGap: TimeInterval = 0

    var settlePause: TimeInterval {
        max(Self.minimumPause, largestRecentGap * 2)
    }

    /// Whatever arrives next starts a new repaint: the application marked the end of this one,
    /// or input that it will answer with another one is on its way.
    mutating func noteRepaintBoundary() {
        lastReadUptime = nil
    }

    mutating func noteRead(atUptime uptime: TimeInterval) {
        defer { lastReadUptime = uptime }
        largestRecentGap *= Self.decayPerRead
        guard let lastReadUptime else { return }
        let gap = uptime - lastReadUptime
        if gap <= Self.maximumGapWithinRepaint {
            largestRecentGap = max(largestRecentGap, gap)
        }
    }
}

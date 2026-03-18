import Foundation
import QuartzCore

final class RenderFPSMonitor {
    static let shared = RenderFPSMonitor()

    private let windowDuration: CFTimeInterval = 1.0
    private let maximumSampleCount = 240
    private var frameTimestamps: [CFTimeInterval] = []

    private init() {}

    func recordFrame(at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        frameTimestamps.append(timestamp)
        trimSamples(now: timestamp)
        if frameTimestamps.count > maximumSampleCount {
            frameTimestamps.removeFirst(frameTimestamps.count - maximumSampleCount)
        }
    }

    func currentFPS(now: CFTimeInterval = CACurrentMediaTime()) -> Double? {
        trimSamples(now: now)
        guard frameTimestamps.count >= 2,
              let first = frameTimestamps.first,
              let last = frameTimestamps.last,
              last > first else {
            return nil
        }
        return Double(frameTimestamps.count - 1) / (last - first)
    }

    func reset() {
        frameTimestamps.removeAll(keepingCapacity: false)
    }

    private func trimSamples(now: CFTimeInterval) {
        let cutoff = now - windowDuration
        if let firstValidIndex = frameTimestamps.firstIndex(where: { $0 >= cutoff }) {
            if firstValidIndex > 0 {
                frameTimestamps.removeFirst(firstValidIndex)
            }
        } else if !frameTimestamps.isEmpty {
            frameTimestamps.removeAll(keepingCapacity: true)
        }
    }
}

import AppKit
import Darwin

final class ProcessMetricsMonitor {
    struct Snapshot {
        let cpuUsageByPID: [pid_t: Double]
        let appMemoryBytes: UInt64
    }

    private struct CPUSample {
        let totalTime: UInt64
        let timestamp: TimeInterval
    }

    var onUpdate: ((Snapshot) -> Void)?

    private var timer: DispatchSourceTimer?
    private var lastSamples: [pid_t: CPUSample] = [:]
    private let interval: TimeInterval
    private let timebaseNumer: Double
    private let timebaseDenom: Double
    private let queue = DispatchQueue(label: "com.pterm.process-metrics-monitor", qos: .utility)

    init(interval: TimeInterval = 3.0) {
        self.interval = interval
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.timebaseNumer = max(1, Double(timebase.numer))
        self.timebaseDenom = max(1, Double(timebase.denom))
    }

    func start(pidsProvider: @escaping () -> [pid_t]) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let repeatingNanoseconds = UInt64(max(0.1, interval) * 1_000_000_000)
        let leewayNanoseconds = UInt64(min(1.0, max(0.05, interval * 0.25)) * 1_000_000_000)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(Int(repeatingNanoseconds)),
            leeway: .nanoseconds(Int(leewayNanoseconds))
        )
        timer.setEventHandler { [weak self] in
            self?.sample(pids: pidsProvider())
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        lastSamples.removeAll(keepingCapacity: false)
    }

    var debugLastSampleCount: Int { lastSamples.count }
    var debugDescendantQueueScratchCapacity: Int { 0 }
    var debugDescendantResultScratchCapacity: Int { 0 }
    var debugChildPIDBufferScratchCapacity: Int { 0 }

    func debugPrimeDescendantScratch(queueCount: Int, resultCount: Int, childCount: Int) {
        _ = (queueCount, resultCount, childCount)
    }

    func debugPrimeLastSamples(_ pids: [pid_t], timestamp: TimeInterval = 1.0) {
        lastSamples = Dictionary(uniqueKeysWithValues: pids.map { ($0, CPUSample(totalTime: 1, timestamp: timestamp)) })
    }

    func debugCompactDescendantScratchForTesting(
        retainingQueueCount queueCount: Int,
        resultCount: Int,
        childCount: Int
    ) {
        _ = (queueCount, resultCount, childCount)
    }

    private func sample(pids: [pid_t]) {
        let now = ProcessInfo.processInfo.systemUptime
        var usage: [pid_t: Double] = [:]
        var nextSamples: [pid_t: CPUSample] = [:]

        for pid in Set(pids) {
            guard let totalTime = processCPUTime(pid: pid) else { continue }
            let sample = CPUSample(totalTime: totalTime, timestamp: now)
            nextSamples[pid] = sample

            if let previous = lastSamples[pid], sample.timestamp > previous.timestamp {
                let deltaTime = cpuTimeSeconds(fromAbsoluteTicks: sample.totalTime &- previous.totalTime)
                let elapsed = sample.timestamp - previous.timestamp
                if elapsed > 0 {
                    let percent = min(999.0, max(0, (deltaTime / elapsed) * 100.0))
                    usage[pid] = percent
                }
            } else {
                usage[pid] = 0
            }
        }

        lastSamples = nextSamples
        let snapshot = Snapshot(
            cpuUsageByPID: usage,
            appMemoryBytes: currentProcessResidentMemory()
        )
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(snapshot)
        }
    }

    private func processCPUTime(pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.stride))
        guard size == Int32(MemoryLayout<proc_taskinfo>.stride) else { return nil }
        return UInt64(info.pti_total_user) + UInt64(info.pti_total_system)
    }

    func cpuTimeSeconds(fromAbsoluteTicks ticks: UInt64) -> Double {
        (Double(ticks) * timebaseNumer / timebaseDenom) / 1_000_000_000.0
    }

    private func currentProcessResidentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}

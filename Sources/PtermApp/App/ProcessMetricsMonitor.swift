import AppKit
import Darwin

final class ProcessMetricsMonitor {
    struct Snapshot {
        let cpuUsageByPID: [pid_t: Double]
        let appMemoryBytes: UInt64
        let currentDirectoryByPID: [pid_t: String]
    }

    private struct CPUSample {
        let totalTime: UInt64
        let timestamp: TimeInterval
    }

    var onUpdate: ((Snapshot) -> Void)?

    private var timer: Timer?
    private var lastSamples: [pid_t: CPUSample] = [:]
    private let interval: TimeInterval
    private let cpuCount: Double

    init(interval: TimeInterval = 3.0) {
        self.interval = interval
        self.cpuCount = max(1, Double(ProcessInfo.processInfo.processorCount))
    }

    func start(pidsProvider: @escaping () -> [pid_t]) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.sample(pids: pidsProvider())
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        sample(pids: pidsProvider())
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample(pids: [pid_t]) {
        let now = ProcessInfo.processInfo.systemUptime
        var usage: [pid_t: Double] = [:]
        var nextSamples: [pid_t: CPUSample] = [:]
        var currentDirectoryByPID: [pid_t: String] = [:]

        for pid in Set(pids) {
            guard let totalTime = processCPUTime(pid: pid) else { continue }
            let sample = CPUSample(totalTime: totalTime, timestamp: now)
            nextSamples[pid] = sample
            if let cwd = processCurrentDirectory(pid: pid) {
                currentDirectoryByPID[pid] = cwd
            }

            if let previous = lastSamples[pid], sample.timestamp > previous.timestamp {
                let deltaTime = Double(sample.totalTime &- previous.totalTime) / 1_000_000.0
                let elapsed = sample.timestamp - previous.timestamp
                if elapsed > 0 {
                    let percent = min(999.0, max(0, (deltaTime / elapsed) * 100.0 / cpuCount))
                    usage[pid] = percent
                }
            } else {
                usage[pid] = 0
            }
        }

        lastSamples = nextSamples
        onUpdate?(Snapshot(
            cpuUsageByPID: usage,
            appMemoryBytes: currentProcessResidentMemory(),
            currentDirectoryByPID: currentDirectoryByPID
        ))
    }

    private func processCPUTime(pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.stride))
        guard size == Int32(MemoryLayout<proc_taskinfo>.stride) else { return nil }
        return UInt64(info.pti_total_user) + UInt64(info.pti_total_system)
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

    private func processCurrentDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.stride))
        guard size == Int32(MemoryLayout<proc_vnodepathinfo>.stride) else { return nil }
        let path = info.pvi_cdir.vip_path
        return withUnsafePointer(to: path) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: path)) {
                String(cString: $0)
            }
        }
    }
}

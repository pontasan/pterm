import AppKit
import Darwin

final class ProcessMetricsMonitor {
    struct Snapshot {
        let cpuUsageByPID: [pid_t: Double]
        let appMemoryBytes: UInt64
        let currentDirectoryByPID: [pid_t: String]
        /// Resident memory per monitored PID including all descendant processes.
        let memoryByPID: [pid_t: UInt64]
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
        var memoryByPID: [pid_t: UInt64] = [:]

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

            // Collect memory for this PID and all its descendants
            let descendants = collectDescendants(of: pid)
            var totalMemory: UInt64 = processResidentMemory(pid: pid)
            for child in descendants {
                totalMemory += processResidentMemory(pid: child)
                // Also track CPU for descendant processes
                if nextSamples[child] == nil,
                   let childTime = processCPUTime(pid: child) {
                    let childSample = CPUSample(totalTime: childTime, timestamp: now)
                    nextSamples[child] = childSample
                    if let prev = lastSamples[child], childSample.timestamp > prev.timestamp {
                        let dt = Double(childSample.totalTime &- prev.totalTime) / 1_000_000.0
                        let elapsed = childSample.timestamp - prev.timestamp
                        if elapsed > 0 {
                            let pct = min(999.0, max(0, (dt / elapsed) * 100.0 / cpuCount))
                            usage[child] = pct
                        }
                    } else {
                        usage[child] = 0
                    }
                }
            }
            memoryByPID[pid] = totalMemory
        }

        lastSamples = nextSamples
        onUpdate?(Snapshot(
            cpuUsageByPID: usage,
            appMemoryBytes: currentProcessResidentMemory(),
            currentDirectoryByPID: currentDirectoryByPID,
            memoryByPID: memoryByPID
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

    private func processResidentMemory(pid: pid_t) -> UInt64 {
        var info = proc_taskinfo()
        let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.stride))
        guard size == Int32(MemoryLayout<proc_taskinfo>.stride) else { return 0 }
        return UInt64(info.pti_resident_size)
    }

    private func collectDescendants(of rootPID: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue: [pid_t] = [rootPID]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            let count = proc_listchildpids(parent, nil, 0)
            guard count > 0 else { continue }
            var childPIDs = [pid_t](repeating: 0, count: Int(count))
            let actual = proc_listchildpids(parent, &childPIDs, count * Int32(MemoryLayout<pid_t>.stride))
            let childCount = Int(actual) / MemoryLayout<pid_t>.stride
            for i in 0..<childCount {
                let child = childPIDs[i]
                if child > 0 {
                    result.append(child)
                    queue.append(child)
                }
            }
        }
        return result
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

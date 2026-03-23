import Darwin
import Foundation
import PtermCore

/// Monitors the process tree of a terminal session using kqueue to detect
/// foreground process changes event-driven (no polling).
///
/// Registers the shell PID with `EVFILT_PROC` for `NOTE_FORK`, `NOTE_EXIT`,
/// and `NOTE_EXEC`.  On fork events, the child PID is chained into monitoring.
/// On exit/exec events, the foreground process is re-evaluated via `tcgetpgrp`.
///
/// Thread safety: all kqueue events are delivered on the provided dispatch queue
/// (typically the PTY read queue).  The `onForegroundProcessChange` callback
/// fires on that same queue.
final class ProcessMonitor {
    /// Called when the foreground process changes.  Delivers the process name
    /// (or nil if the name could not be resolved).
    var onForegroundProcessChange: ((String?) -> Void)?

    private let kqFD: Int32
    private let masterFD: Int32
    private var monitoredPIDs: Set<pid_t> = []
    private var dispatchSource: DispatchSourceRead?
    private let queue: DispatchQueue
    private var stopped = false

    /// Maximum number of simultaneously monitored PIDs to prevent resource
    /// exhaustion from fork bombs.
    static let maxMonitoredPIDs = 256

    /// Create a process monitor for a terminal session.
    ///
    /// - Parameters:
    ///   - masterFD: The PTY master file descriptor (for `tcgetpgrp` calls).
    ///   - shellPID: The PID of the shell process (direct child of pterm).
    ///   - queue: The dispatch queue for event delivery (should be the PTY read queue).
    init?(masterFD: Int32, shellPID: pid_t, queue: DispatchQueue) {
        let kq = kqueue()
        guard kq >= 0 else { return nil }

        // Set close-on-exec to prevent leak to child processes.
        _ = fcntl(kq, F_SETFD, FD_CLOEXEC)

        self.kqFD = kq
        self.masterFD = masterFD
        self.queue = queue

        registerPID(shellPID)
    }

    deinit {
        stop()
    }

    func start() {
        guard dispatchSource == nil else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: kqFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainEvents()
        }
        source.setCancelHandler { /* intentionally empty — kqFD closed in stop() */ }
        self.dispatchSource = source
        source.resume()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true

        if let source = dispatchSource {
            source.cancel()
            dispatchSource = nil
        }

        // Explicitly deregister all monitored PIDs before closing the kqueue fd.
        for pid in monitoredPIDs {
            pterm_kqueue_deregister_pid(kqFD, pid)
        }
        monitoredPIDs.removeAll()

        close(kqFD)
    }

    // MARK: - PID Registration

    private func registerPID(_ pid: pid_t) {
        guard pid > 0 else { return }
        guard monitoredPIDs.count < Self.maxMonitoredPIDs else {
            NSLog("[pterm] ProcessMonitor: high-water mark reached (%d PIDs), skipping PID %d",
                  Self.maxMonitoredPIDs, pid)
            return
        }
        guard !monitoredPIDs.contains(pid) else { return }

        if pterm_kqueue_register_pid(kqFD, pid) == 0 {
            monitoredPIDs.insert(pid)
        }
        // If registration fails (e.g. process already exited), silently ignore.
    }

    // MARK: - Event Handling

    private static let eventBufferCount = 16

    private func drainEvents() {
        let evBuf = UnsafeMutablePointer<kevent>.allocate(capacity: Self.eventBufferCount)
        defer { evBuf.deallocate() }
        var foregroundChanged = false

        while true {
            let count = pterm_kqueue_poll(kqFD, evBuf, Int32(Self.eventBufferCount))
            guard count > 0 else { break }

            for i in 0..<Int(count) {
                let evPtr = evBuf.advanced(by: i)

                if pterm_kevent_has_note(evPtr, UInt32(NOTE_FORK)) != 0 {
                    let childPID = pterm_kevent_fork_child_pid(evPtr)
                    if childPID > 0 {
                        registerPID(childPID)
                    }
                }

                if pterm_kevent_has_note(evPtr, UInt32(NOTE_EXIT)) != 0 {
                    let pid = pterm_kevent_pid(evPtr)
                    monitoredPIDs.remove(pid)
                    foregroundChanged = true
                }

                if pterm_kevent_has_note(evPtr, UInt32(NOTE_EXEC)) != 0 {
                    foregroundChanged = true
                }
            }
        }

        if foregroundChanged {
            notifyForegroundChange()
        }
    }

    private func notifyForegroundChange() {
        let pgid = tcgetpgrp(masterFD)
        let name: String?
        if pgid > 0 {
            name = ProcessInspection.processName(pid: pgid)
        } else {
            name = nil
        }
        onForegroundProcessChange?(name)
    }
}

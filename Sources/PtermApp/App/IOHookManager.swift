import Darwin
import Foundation
import PtermCore

/// Central orchestrator for I/O hooks.
///
/// Manages hook process lifecycle (spawn → monitor → shutdown), per-hook-per-terminal
/// ring buffers, delivery threads, and foreground process matching.  One instance
/// exists per app when the master switch is ON; deallocated when turned OFF.
///
/// Thread safety:
/// - `activateTerminal` / `deactivateTerminal` / `shutdown` are called from the
///   main thread (Settings reload, terminal creation/destruction).
/// - `dispatchRaw*` / `dispatchText` are called from the PTY read queue.
/// - Delivery threads drain ring buffers and write to pipes.
/// - Internal state is protected by `stateLock` (NSLock).
final class IOHookManager {

    // MARK: - Types

    /// Unique key identifying an active hook instance.
    private struct InstanceKey: Hashable {
        let terminalID: UUID
        let hookIndex: Int
    }

    /// State for a single active hook instance (one hook × one terminal).
    private final class ActiveHookInstance {
        let hookEntry: IOHookEntry
        let terminalID: UUID
        let ringBuffer: OpaquePointer  // SPSCRingBuffer*
        let deliveryQueue: DispatchQueue
        var pipeFD: Int32 = -1
        var hookPID: pid_t = 0
        var active: Bool = true

        // Line-mode accumulator (text between newlines).
        var lineBuffer = Data()

        // Idle-mode state (Phase 6 — stubbed for now).
        var dirtyLines: Set<Int> = []
        var lastOutputTime: UInt64 = 0
        var idleTimer: DispatchSourceTimer?
        var previousSnapshot: [Int: String] = [:]

        init(hookEntry: IOHookEntry, terminalID: UUID, ringBuffer: OpaquePointer,
             deliveryQueue: DispatchQueue) {
            self.hookEntry = hookEntry
            self.terminalID = terminalID
            self.ringBuffer = ringBuffer
            self.deliveryQueue = deliveryQueue
        }

        deinit {
            spsc_ring_buffer_destroy(ringBuffer)
        }
    }

    // MARK: - Properties

    private let config: IOHookConfiguration

    /// All active hook instances, keyed by (terminalID, hookIndex).
    private var instances: [InstanceKey: ActiveHookInstance] = [:]

    /// Process monitors per terminal (for process_match evaluation).
    private var processMonitors: [UUID: ProcessMonitor] = [:]

    /// Current foreground process name per terminal.
    private var foregroundProcessNames: [UUID: String?] = [:]

    /// PIDs of hook child processes (to prevent recursive hooking).
    private var hookChildPIDs: Set<pid_t> = []

    /// Per-terminal grid reader for idle mode.  The closure reads row text
    /// from the grid under a read lock.  Set by TerminalController when
    /// idle-mode hooks are active.
    /// Signature: (row: Int, cols: Int) -> String?
    private var gridReaders: [UUID: (Int, Int) -> String?] = [:]

    /// Per-terminal PTY read queue for idle timer scheduling.
    private var ptyQueues: [UUID: DispatchQueue] = [:]

    /// Per-terminal grid dimensions (rows, cols) for idle mode.
    private var gridDimensions: [UUID: (rows: Int, cols: Int)] = [:]

    /// Protects all mutable state above.
    private let stateLock = NSLock()

    /// Set once during shutdown to reject new operations.
    private var isShutdown = false

    /// Graceful shutdown timeout before SIGTERM.
    static let pipeCloseWaitSeconds: Int = 5
    /// Forceful kill timeout after SIGTERM.
    static let sigkillWaitSeconds: Int = 2

    // MARK: - Init / Shutdown

    /// Create a hook manager.  Only call when `config.enabled` is true
    /// and at least one hook entry exists.
    init(config: IOHookConfiguration) {
        precondition(config.enabled, "IOHookManager must not be created when master switch is OFF")
        self.config = config
    }

    /// Shut down all hooks and process monitors.  After this call, the
    /// manager rejects all further operations.
    func shutdown() {
        stateLock.lock()
        guard !isShutdown else { stateLock.unlock(); return }
        isShutdown = true

        let allInstances = instances
        let allMonitors = processMonitors
        instances.removeAll()
        processMonitors.removeAll()
        foregroundProcessNames.removeAll()
        hookChildPIDs.removeAll()
        gridReaders.removeAll()
        ptyQueues.removeAll()
        gridDimensions.removeAll()
        stateLock.unlock()

        for (_, instance) in allInstances {
            shutdownInstance(instance)
        }
        for (_, monitor) in allMonitors {
            monitor.stop()
        }
    }

    deinit {
        shutdown()
    }

    /// Force-kill all running hook processes immediately (SIGKILL) and respawn
    /// matching hooks.  This is a development aid triggered by the "Reset Hook
    /// Processes" button in Settings.
    ///
    /// Unlike `shutdown()`, the manager remains alive and fully operational
    /// after this call.
    func forceResetAllProcesses() {
        stateLock.lock()
        guard !isShutdown else { stateLock.unlock(); return }

        // Snapshot all instances and the terminal IDs that had active hooks.
        let allInstances = instances
        let terminalIDs = Set(allInstances.values.map(\.terminalID))
        instances.removeAll()
        hookChildPIDs.removeAll()
        stateLock.unlock()

        // Force-kill every hook process immediately — no graceful shutdown.
        // Use -pid to kill the entire process group (sh + children).
        for (_, instance) in allInstances {
            instance.active = false
            instance.idleTimer?.cancel()
            instance.idleTimer = nil
            if instance.pipeFD >= 0 {
                close(instance.pipeFD)
                instance.pipeFD = -1
            }
            if instance.hookPID > 0 {
                kill(-instance.hookPID, SIGKILL)
                var status: Int32 = 0
                waitpid(instance.hookPID, &status, 0)
            }
        }

        // Re-evaluate and respawn hooks for all previously active terminals.
        for terminalID in terminalIDs {
            evaluateAndActivateHooks(terminalID: terminalID)
        }
    }

    /// Returns the number of currently active hook instances.
    var activeInstanceCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return instances.values.filter(\.active).count
    }

    // MARK: - Terminal Lifecycle

    /// Begin monitoring a terminal and activate matching hooks.
    ///
    /// - Parameters:
    ///   - id: Terminal UUID.
    ///   - masterFD: PTY master fd (for tcgetpgrp).
    ///   - shellPID: Shell process PID (direct child).
    ///   - ptyQueue: The PTY read dispatch queue.
    func activateTerminal(id: UUID, masterFD: Int32, shellPID: pid_t,
                          ptyQueue: DispatchQueue) {
        stateLock.lock()
        guard !isShutdown else { stateLock.unlock(); return }
        stateLock.unlock()

        NSLog("[pterm] IOHookManager.activateTerminal: id=%@ shellPID=%d", id.uuidString, shellPID)
        // Determine initial foreground process name.
        let fgName = ProcessInspection.processName(pid: shellPID)

        stateLock.lock()
        foregroundProcessNames[id] = fgName
        ptyQueues[id] = ptyQueue
        stateLock.unlock()

        // Set up process monitor if any hook uses process_match.
        let needsMonitor = config.hooks.contains { $0.enabled && $0.processMatch != nil }
        if needsMonitor {
            if let monitor = ProcessMonitor(masterFD: masterFD, shellPID: shellPID,
                                            queue: ptyQueue) {
                monitor.onForegroundProcessChange = { [weak self] name in
                    self?.handleForegroundProcessChange(terminalID: id, processName: name)
                }
                stateLock.lock()
                processMonitors[id] = monitor
                stateLock.unlock()
                monitor.start()
            }
        }

        // Evaluate which hooks match and activate them.
        evaluateAndActivateHooks(terminalID: id)
    }

    /// Tear down all hooks and monitoring for a terminal.
    func deactivateTerminal(id: UUID) {
        stateLock.lock()
        guard !isShutdown else { stateLock.unlock(); return }

        let monitor = processMonitors.removeValue(forKey: id)
        foregroundProcessNames.removeValue(forKey: id)
        gridReaders.removeValue(forKey: id)
        ptyQueues.removeValue(forKey: id)
        gridDimensions.removeValue(forKey: id)

        // Collect instances for this terminal.
        let keys = instances.keys.filter { $0.terminalID == id }
        var toShutdown: [ActiveHookInstance] = []
        for key in keys {
            if let instance = instances.removeValue(forKey: key) {
                toShutdown.append(instance)
            }
        }
        stateLock.unlock()

        monitor?.stop()
        for instance in toShutdown {
            shutdownInstance(instance)
        }
    }

    // MARK: - Data Dispatch (called from PTY read queue)

    /// Dispatch raw PTY output bytes to immediate-mode hooks for a terminal.
    func dispatchRawOutput(_ bytes: UnsafeBufferPointer<UInt8>, terminalID: UUID) {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }

        stateLock.lock()
        let relevant = instances.values.filter {
            $0.terminalID == terminalID && $0.active &&
            $0.hookEntry.target == .output && $0.hookEntry.buffering == .immediate
        }
        stateLock.unlock()

        for instance in relevant {
            spsc_ring_buffer_write(instance.ringBuffer, base, bytes.count)
            instance.deliveryQueue.async { [weak self] in
                self?.drainAndWrite(instance)
            }
        }
    }

    /// Dispatch raw input data to stdin hooks for a terminal.
    func dispatchRawInput(_ data: Data, terminalID: UUID) {
        guard !data.isEmpty else { return }

        stateLock.lock()
        let relevant = instances.values.filter {
            $0.terminalID == terminalID && $0.active &&
            $0.hookEntry.target == .stdin
        }
        stateLock.unlock()

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for instance in relevant {
                spsc_ring_buffer_write(instance.ringBuffer, base, rawBuf.count)
                instance.deliveryQueue.async { [weak self] in
                    self?.drainAndWrite(instance)
                }
            }
        }
    }

    /// Dispatch a line of clean text to line-mode hooks for a terminal.
    /// Called from the VT parser's print action accumulator.
    func dispatchTextLine(_ line: String, terminalID: UUID) {
        guard !line.isEmpty else { return }
        guard let utf8 = line.data(using: .utf8) else { return }

        stateLock.lock()
        let relevant = instances.values.filter {
            $0.terminalID == terminalID && $0.active &&
            $0.hookEntry.target == .output && $0.hookEntry.buffering == .line
        }
        stateLock.unlock()

        // Write line + newline to ring buffer.
        var payload = utf8
        payload.append(0x0A)  // '\n'

        payload.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for instance in relevant {
                spsc_ring_buffer_write(instance.ringBuffer, base, rawBuf.count)
                instance.deliveryQueue.async { [weak self] in
                    self?.drainAndWrite(instance)
                }
            }
        }
    }

    /// Accumulate a character for line-mode hooks.  Flush on newline.
    func dispatchTextCharacter(_ char: UInt32, terminalID: UUID) {
        stateLock.lock()
        let relevant = instances.values.filter {
            $0.terminalID == terminalID && $0.active &&
            $0.hookEntry.target == .output && $0.hookEntry.buffering == .line
        }
        stateLock.unlock()

        guard !relevant.isEmpty else { return }

        // Convert UInt32 to UTF-8 bytes.
        let scalar = Unicode.Scalar(char) ?? Unicode.Scalar(0xFFFD)!
        let character = Character(scalar)
        let utf8Bytes = Array(String(character).utf8)

        // Only LF (0x0A) triggers a flush.  CR (0x0D) is ignored entirely:
        // in terminal output, `\r\n` means newline (LF will flush), and `\r`
        // alone means carriage return (cursor to column 0, not a new line).
        // Flushing on both CR and LF would produce spurious empty lines.
        let isLF = char == 0x0A
        let isCR = char == 0x0D

        for instance in relevant {
            if isLF {
                // Flush accumulated line.
                var payload = instance.lineBuffer
                payload.append(0x0A)  // '\n'
                instance.lineBuffer.removeAll(keepingCapacity: true)

                payload.withUnsafeBytes { rawBuf in
                    guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    spsc_ring_buffer_write(instance.ringBuffer, base, rawBuf.count)
                }
                instance.deliveryQueue.async { [weak self] in
                    self?.drainAndWrite(instance)
                }
            } else if isCR {
                // Ignore CR — do not accumulate it into the line buffer.
                // CR alone means "return to column 0" which doesn't produce
                // a new line of output.
            } else {
                instance.lineBuffer.append(contentsOf: utf8Bytes)
            }
        }
    }

    // MARK: - Query

    /// Check whether a PID is a hook child process (recursive prevention).
    func isHookChildProcess(_ pid: pid_t) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return hookChildPIDs.contains(pid)
    }

    /// Returns true if any hook is active for the given terminal.
    func hasActiveHooks(for terminalID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return instances.values.contains {
            $0.terminalID == terminalID && $0.active
        }
    }

    /// Returns true if any hook uses line or idle buffering for the given terminal.
    func needsTextCapture(for terminalID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return instances.values.contains {
            $0.terminalID == terminalID && $0.active &&
            $0.hookEntry.target == .output &&
            ($0.hookEntry.buffering == .line || $0.hookEntry.buffering == .idle)
        }
    }

    // MARK: - Idle Mode

    /// Register a grid reader for idle-mode text extraction.
    /// The closure reads a row's text content under a read lock.
    /// Called by TerminalController when idle-mode hooks are active.
    ///
    /// - Parameters:
    ///   - terminalID: Terminal UUID.
    ///   - rows: Number of grid rows.
    ///   - cols: Number of grid columns.
    ///   - reader: Closure that takes (row, cols) and returns the trimmed
    ///     text content of that row, or nil if out of bounds.
    func registerGridReader(terminalID: UUID, rows: Int, cols: Int,
                            reader: @escaping (Int, Int) -> String?) {
        stateLock.lock()
        gridReaders[terminalID] = reader
        gridDimensions[terminalID] = (rows, cols)
        stateLock.unlock()
    }

    /// Update grid dimensions after a resize.
    func updateGridDimensions(terminalID: UUID, rows: Int, cols: Int) {
        stateLock.lock()
        gridDimensions[terminalID] = (rows, cols)
        stateLock.unlock()
    }

    /// Notify that a row has been modified (for idle mode dirty tracking).
    /// Called from the PTY read queue (same queue as idle timer — no lock
    /// needed for dirtyLines per the spec's concurrency guarantee).
    func notifyDirtyRow(_ row: Int, terminalID: UUID) {
        stateLock.lock()
        let idleInstances = instances.values.filter {
            $0.terminalID == terminalID && $0.active &&
            $0.hookEntry.target == .output && $0.hookEntry.buffering == .idle
        }
        let ptyQueue = ptyQueues[terminalID]
        stateLock.unlock()

        guard !idleInstances.isEmpty else { return }

        let now = mach_absolute_time()

        for instance in idleInstances {
            instance.dirtyLines.insert(row)
            instance.lastOutputTime = now

            // Reschedule idle timer.
            rescheduleIdleTimer(instance, ptyQueue: ptyQueue)
        }
    }

    /// Notify that the terminal has been resized.
    /// Clears previousSnapshot and dirtyLines — all row indices are invalid.
    func notifyResize(terminalID: UUID) {
        stateLock.lock()
        let idleInstances = instances.values.filter {
            $0.terminalID == terminalID && $0.active &&
            $0.hookEntry.target == .output && $0.hookEntry.buffering == .idle
        }
        stateLock.unlock()

        for instance in idleInstances {
            instance.previousSnapshot.removeAll()
            instance.dirtyLines.removeAll()
        }
    }

    /// Notify that the terminal switched to/from alternate screen buffer.
    /// Clears previousSnapshot and dirtyLines — grid content replaced wholesale.
    func notifyAlternateScreenChange(terminalID: UUID) {
        stateLock.lock()
        let idleInstances = instances.values.filter {
            $0.terminalID == terminalID && $0.active &&
            $0.hookEntry.target == .output && $0.hookEntry.buffering == .idle
        }
        stateLock.unlock()

        for instance in idleInstances {
            instance.previousSnapshot.removeAll()
            instance.dirtyLines.removeAll()
        }
    }

    /// Returns true if any active idle-mode hook exists for a terminal.
    func needsIdleMode(for terminalID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return instances.values.contains {
            $0.terminalID == terminalID && $0.active &&
            $0.hookEntry.target == .output && $0.hookEntry.buffering == .idle
        }
    }

    // MARK: - Private: Idle Timer

    private func rescheduleIdleTimer(_ instance: ActiveHookInstance,
                                      ptyQueue: DispatchQueue?) {
        guard let ptyQueue else { return }

        let idleMs = instance.hookEntry.idleMs

        if let timer = instance.idleTimer {
            // Reschedule existing timer.
            timer.schedule(deadline: .now() + .milliseconds(idleMs))
        } else {
            // Create new timer on the PTY read queue.
            let timer = DispatchSource.makeTimerSource(queue: ptyQueue)
            timer.schedule(deadline: .now() + .milliseconds(idleMs))
            timer.setEventHandler { [weak self] in
                self?.handleIdleTimerFire(instance)
            }
            instance.idleTimer = timer
            timer.resume()
        }
    }

    private func handleIdleTimerFire(_ instance: ActiveHookInstance) {
        guard instance.active else { return }

        // Check if output is still arriving (timer may fire while new data comes).
        let now = mach_absolute_time()
        let elapsedNs = machTimeToNanoseconds(now - instance.lastOutputTime)
        let idleNs = UInt64(instance.hookEntry.idleMs) * 1_000_000

        if elapsedNs < idleNs {
            // Output still arriving.  Reschedule the timer for the remaining
            // idle period so it fires again after the output truly stops.
            // Without this, the one-shot timer would not fire again and dirty
            // rows would be silently lost.
            let remainingMs = Int((idleNs - elapsedNs) / 1_000_000) + 1
            instance.idleTimer?.schedule(deadline: .now() + .milliseconds(remainingMs))
            return
        }

        guard !instance.dirtyLines.isEmpty else { return }

        // Read ALL rows from the grid (not just dirty ones) to produce
        // a complete screen snapshot.  Compare against previousSnapshot
        // to detect whether the screen has changed.  If changed, send
        // the entire visible text so the hook script receives a coherent
        // screen state (e.g. ⏺ ... ❯ markers are preserved together).
        stateLock.lock()
        let reader = gridReaders[instance.terminalID]
        let dims = gridDimensions[instance.terminalID]
        stateLock.unlock()

        guard let reader, let dims else { return }

        instance.dirtyLines.removeAll()

        // Build current full-screen snapshot.
        var currentSnapshot: [Int: String] = [:]
        var currentLines: [String] = []
        var hasChange = false

        for row in 0..<dims.rows {
            let currentText = reader(row, dims.cols)
            let trimmed = currentText?.trimmingCharacters(in: .whitespaces) ?? ""
            currentSnapshot[row] = trimmed

            if trimmed != (instance.previousSnapshot[row] ?? "") {
                hasChange = true
            }
            if !trimmed.isEmpty {
                currentLines.append(trimmed)
            }
        }

        guard hasChange else { return }

        let outputLines: [String]
        if instance.hookEntry.diffOnly {
            // LCS-based diff: extract lines added or changed in current
            // relative to previous, preserving order.
            let previousLines: [String] = (0..<dims.rows).compactMap { row in
                let text = instance.previousSnapshot[row] ?? ""
                return text.isEmpty ? nil : text
            }
            outputLines = LineDiff.addedLines(previous: previousLines, current: currentLines)
        } else {
            outputLines = currentLines
        }

        instance.previousSnapshot = currentSnapshot

        guard !outputLines.isEmpty else {
            // Snapshot changed (e.g. lines removed) but no new content to send.
            return
        }

        // Write to ring buffer.  Append NUL delimiter (\0) after the final
        // newline so that consumers can distinguish chunk boundaries
        // (e.g. `read -d ''` in shell scripts).
        let payload = outputLines.joined(separator: "\n") + "\n\0"

        // DEBUG: dump raw payload to file for diagnosis.
        if let debugData = payload.data(using: .utf8) {
            try? debugData.write(to: URL(fileURLWithPath: "/tmp/pterm_idle_payload_debug.bin"))
        }

        if let data = payload.data(using: .utf8) {
            // data(using:) encodes the NUL as the literal byte 0x00,
            // which is exactly what we want.
            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                spsc_ring_buffer_write(instance.ringBuffer, base, rawBuf.count)
            }
            instance.deliveryQueue.async { [weak self] in
                self?.drainAndWrite(instance)
            }
        }

        // Cancel timer — will be recreated when next output arrives.
        instance.idleTimer?.cancel()
        instance.idleTimer = nil
    }

    /// Convert mach_absolute_time delta to nanoseconds.
    private static var timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private func machTimeToNanoseconds(_ elapsed: UInt64) -> UInt64 {
        let info = Self.timebaseInfo
        return elapsed * UInt64(info.numer) / UInt64(info.denom)
    }

    // MARK: - Private: Hook Evaluation

    private func handleForegroundProcessChange(terminalID: UUID, processName: String?) {
        stateLock.lock()
        foregroundProcessNames[terminalID] = processName
        stateLock.unlock()

        evaluateAndActivateHooks(terminalID: terminalID)
    }

    /// Evaluate which hooks should be active for a terminal and start/stop
    /// instances as needed.
    private func evaluateAndActivateHooks(terminalID: UUID) {
        stateLock.lock()
        guard !isShutdown else { stateLock.unlock(); return }
        let fgName = foregroundProcessNames[terminalID] ?? nil
        stateLock.unlock()

        for (index, hook) in config.hooks.enumerated() {
            guard hook.enabled else { continue }

            let key = InstanceKey(terminalID: terminalID, hookIndex: index)
            let shouldBeActive = matchesProcess(hook: hook, processName: fgName)

            stateLock.lock()
            let existingInstance = instances[key]
            stateLock.unlock()

            if shouldBeActive && existingInstance == nil {
                // Activate: create ring buffer, spawn process, start delivery.
                activateInstance(key: key, hook: hook, terminalID: terminalID)
            } else if !shouldBeActive, let instance = existingInstance {
                // Deactivate: stop and remove.
                stateLock.lock()
                instances.removeValue(forKey: key)
                stateLock.unlock()
                shutdownInstance(instance)
            }
        }
    }

    /// Check if a hook's process_match matches the given foreground process name.
    private func matchesProcess(hook: IOHookEntry, processName: String?) -> Bool {
        guard let regex = hook.processMatchRegex else {
            // No process_match means match all.
            return true
        }
        guard let name = processName, !name.isEmpty else {
            return false
        }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    // MARK: - Private: Instance Lifecycle

    private func activateInstance(key: InstanceKey, hook: IOHookEntry,
                                  terminalID: UUID) {
        // Create ring buffer.
        guard let rb = spsc_ring_buffer_create(hook.bufferSize) else {
            NSLog("[pterm] IOHookManager: failed to create ring buffer for hook '%@'",
                  hook.name)
            return
        }

        let queueLabel = "com.pterm.hook.\(hook.name).\(terminalID.uuidString.prefix(8))"
        let queue = DispatchQueue(label: queueLabel, qos: .utility)

        let instance = ActiveHookInstance(
            hookEntry: hook,
            terminalID: terminalID,
            ringBuffer: rb,
            deliveryQueue: queue
        )

        // Spawn hook process.
        let (pid, writeFD) = spawnHookProcess(command: hook.command)
        guard pid > 0, writeFD >= 0 else {
            NSLog("[pterm] IOHookManager: failed to spawn hook process for '%@'",
                  hook.name)
            // Ring buffer freed in ActiveHookInstance.deinit.
            return
        }

        instance.hookPID = pid
        instance.pipeFD = writeFD

        stateLock.lock()
        instances[key] = instance
        hookChildPIDs.insert(pid)
        stateLock.unlock()
    }

    private func shutdownInstance(_ instance: ActiveHookInstance) {
        instance.active = false

        // Cancel idle timer if present.
        instance.idleTimer?.cancel()
        instance.idleTimer = nil

        let pid = instance.hookPID
        let pipeFD = instance.pipeFD

        // Remove from hook child PIDs.
        stateLock.lock()
        hookChildPIDs.remove(pid)
        stateLock.unlock()

        // Close pipe write end — hook process receives EOF.
        if pipeFD >= 0 {
            close(pipeFD)
            instance.pipeFD = -1
        }

        guard pid > 0 else { return }

        // Wait for graceful exit, then escalate.
        DispatchQueue.global(qos: .utility).async {
            Self.waitAndKill(pid: pid)
        }
    }

    /// Wait for a hook process to exit gracefully, then SIGTERM, then SIGKILL.
    private static func waitAndKill(pid: pid_t) {
        // Check if already exited.
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result == -1 && errno == ECHILD) {
            return  // Already exited or not our child.
        }

        // Wait up to pipeCloseWaitSeconds for graceful exit.
        for _ in 0..<(pipeCloseWaitSeconds * 10) {
            usleep(100_000)  // 100ms
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid || (r == -1 && errno == ECHILD) { return }
        }

        // Send SIGTERM to the entire process group (sh + children).
        kill(-pid, SIGTERM)

        // Wait up to sigkillWaitSeconds.
        for _ in 0..<(sigkillWaitSeconds * 10) {
            usleep(100_000)
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid || (r == -1 && errno == ECHILD) { return }
        }

        // Force kill the entire process group.
        kill(-pid, SIGKILL)
        waitpid(pid, &status, 0)
    }

    // MARK: - Private: Hook Process Spawning

    /// Spawn a hook process via `/bin/sh -c "<command>"`.
    /// Returns (pid, pipe write fd).  Returns (-1, -1) on failure.
    private func spawnHookProcess(command: String) -> (pid_t, Int32) {
        // Create pipe: pipe[0] = read end (child stdin), pipe[1] = write end (parent).
        var pipeFDs: [Int32] = [0, 0]
        guard Darwin.pipe(&pipeFDs) == 0 else { return (-1, -1) }

        let readEnd = pipeFDs[0]
        let writeEnd = pipeFDs[1]

        // Set close-on-exec on the write end so it doesn't leak to the child.
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

        // posix_spawn attributes: new process group, close fds.
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attrs, 0)

        // File actions: dup read end to stdin, close both pipe ends, redirect
        // stdout/stderr to /dev/null.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, readEnd, STDIN_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, readEnd)
        posix_spawn_file_actions_addclose(&fileActions, writeEnd)

        // Redirect stdout and stderr to /dev/null.
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null",
                                         O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null",
                                         O_WRONLY, 0)

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sh"),
            strdup("-c"),
            strdup(command),
            nil
        ]
        defer { for arg in argv { free(arg) } }

        let spawnResult = posix_spawn(&pid, "/bin/sh", &fileActions, &attrs,
                                      argv, environ)

        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attrs)

        // Close the read end in the parent.
        close(readEnd)

        if spawnResult != 0 {
            close(writeEnd)
            return (-1, -1)
        }

        return (pid, writeEnd)
    }

    // MARK: - Private: Ring Buffer Drain & Pipe Write

    /// Drain the ring buffer and write to the pipe fd.
    /// Called on the hook's delivery queue.
    private func drainAndWrite(_ instance: ActiveHookInstance) {
        guard instance.active else { return }

        let bufferSize = 8192
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buf.deallocate() }

        while instance.active {
            let bytesRead = spsc_ring_buffer_read(instance.ringBuffer, buf, bufferSize)
            guard bytesRead > 0 else { break }

            var offset = 0
            while offset < bytesRead && instance.active {
                let written = Darwin.write(instance.pipeFD, buf.advanced(by: offset),
                                           bytesRead - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EPIPE {
                        // Hook process crashed or closed stdin.
                        NSLog("[pterm] IOHookManager: EPIPE for hook '%@' — deactivating",
                              instance.hookEntry.name)
                        instance.active = false

                        stateLock.lock()
                        hookChildPIDs.remove(instance.hookPID)
                        stateLock.unlock()
                    }
                    return
                }
                offset += written
            }
        }
    }
}

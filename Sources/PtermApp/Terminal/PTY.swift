import Foundation
import PtermCore
import Darwin

/// Error type for PTY operations.
enum PTYError: Error {
    case forkptyFailed(String)
    case shellNotFound(String)
    case executableNotFound(String)
}

/// Manages a pseudo-terminal (PTY) for communicating with a child shell process.
///
/// Creates a PTY pair via forkpty(), spawns the user's shell (zsh/bash/sh),
/// and provides non-blocking I/O for reading output and writing input.
///
/// Thread safety: All access to masterFD and isRunning is protected by fdLock
/// to prevent data races between the GCD read source and stop()/write() calls.
final class PTY {
    private enum ControlCharacter {
        static let endOfTransmission: UInt8 = 0x04
    }

    private enum ReadBufferPolicy {
        static let minimumCapacity = 4096
        static let preferredCapacity = 65536
        static let maximumBatchBytes = 1024 * 1024
    }

    private struct PendingWrite {
        let data: Data
        var offset: Int = 0

        var remainingByteCount: Int {
            data.count - offset
        }
    }

    static let readQueue = DispatchQueue(
        label: "com.pterm.pty.read",
        qos: .userInitiated
    )

    private static let writeQueue = DispatchQueue(
        label: "com.pterm.pty.write",
        qos: .userInteractive
    )

    /// File descriptor of the PTY master side
    private var masterFD: Int32 = -1

    /// Read-only access to masterFD for ProcessMonitor (tcgetpgrp) and tests.
    var testMasterFD: Int32 {
        fdLock.lock()
        defer { fdLock.unlock() }
        return masterFD
    }

    /// PID of the child process
    private(set) var childPID: pid_t = 0

    /// Whether the child process is still running
    private var _isRunning: Bool = false
    var isRunning: Bool {
        fdLock.lock()
        defer { fdLock.unlock() }
        return _isRunning
    }

    /// Lock protecting masterFD and _isRunning against concurrent access
    private let fdLock = NSLock()

    /// Dispatch source for reading PTY output
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var childTerminationStatus: Int32?

    /// Signals that the child process has fully exited and been reaped.
    private let exitSemaphore = DispatchSemaphore(value: 0)

    /// Reusable read buffer to avoid allocating on every PTY event.
    /// The same storage also backs aggregated output batches, so the hot read
    /// path can stay on raw bytes until a caller explicitly needs `Data`.
    private var readBuffer: UnsafeMutablePointer<UInt8>?
    private var readBufferCapacity = 0
    private let readBufferLock = NSLock()
    private var aggregatedReadData = Data()

    /// Callback invoked when data is available from the PTY
    var onOutput: ((Data) -> Void)?
    var onOutputBytes: ((UnsafeBufferPointer<UInt8>) -> Void)?

    /// Callback invoked when the child process exits
    var onExit: (() -> Void)?

    var normalizedExitCode: Int32 {
        exitStateLock.lock()
        let status = childTerminationStatus
        exitStateLock.unlock()
        guard let status else { return EXIT_FAILURE }
        if Self.didExitNormally(status) {
            return Self.exitStatus(status)
        }
        if Self.wasTerminatedBySignal(status) {
            return 128 + Self.terminationSignal(status)
        }
        return EXIT_FAILURE
    }

    private let exitStateLock = NSLock()
    private var childExitObserved = false
    private var readChannelClosed = false
    private var exitNotified = false

    private var pendingHighPriorityWrites: [PendingWrite] = []
    private var pendingRegularWrites: [PendingWrite] = []
    private var activeHighPriorityWrite: PendingWrite?
    private var activeRegularWrite: PendingWrite?

    /// Terminal size (rows x cols)
    private var termRows: UInt16 = 24
    private var termCols: UInt16 = 80

    deinit {
        stop()
    }

    var debugReadBufferCapacity: Int {
        readBufferLock.lock()
        defer { readBufferLock.unlock() }
        return readBufferCapacity
    }

    func debugPrimeReadBufferCapacity(_ capacity: Int) {
        readBufferLock.lock()
        defer { readBufferLock.unlock() }
        let normalized = max(ReadBufferPolicy.minimumCapacity, capacity)
        ensureReadBufferCapacityLocked(normalized)
    }

    func debugShrinkIdleReadBufferNow() {
        shrinkIdleReadBufferIfNeeded()
    }

    /// Start the PTY with the specified terminal size.
    /// Spawns the user's preferred shell as the child process.
    /// Throws PTYError.forkptyFailed if forkpty() fails.
    func start(rows: UInt16,
               cols: UInt16,
               termEnv: String = "xterm-256color",
               initialDirectory: String? = nil,
               shellLaunchOrder: [String] = ShellLaunchConfiguration.default.launchOrder,
               slaveTerminalAttributes: termios? = nil,
               executablePath: String? = nil,
               arguments: [String] = []) throws {
        // Validate TERM value: only allow alphanumeric and hyphens
        let validTerm = termEnv.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
        let safeTerm = validTerm ? termEnv : "xterm-256color"

        termRows = rows
        termCols = cols

        var winSize = winsize(
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        let resolvedShellPath = Self.resolveShellPath(
            launchOrder: shellLaunchOrder,
            userShellPath: resolvedUserShellPath(),
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        )
        guard let resolvedShellPath else {
            throw PTYError.shellNotFound("No executable shell found in launch order: \(shellLaunchOrder.joined(separator: ", "))")
        }

        let resolvedExecutablePath: String?
        if let executablePath {
            guard let directPath = Self.resolveExecutablePath(
                executablePath,
                isExecutable: FileManager.default.isExecutableFile(atPath:)
            ) else {
                throw PTYError.executableNotFound("No executable found at path: \(executablePath)")
            }
            resolvedExecutablePath = directPath
        } else {
            resolvedExecutablePath = nil
        }

        // ── Create PTY pair ──────────────────────────────────────────────
        // Use openpty() instead of forkpty() so we can set FD_CLOEXEC on the
        // master fd *before* fork().  This is the industry-standard approach
        // (Alacritty, kitty, Ghostty all do the same) and eliminates the race
        // window where a concurrent fork could inherit an un-CLOEXEC'd master.
        //
        // The syscall sequence below is identical to what Apple's libc forkpty()
        // does internally (openpty → fork → login_tty → close), except we insert
        // fcntl(FD_CLOEXEC) between openpty() and fork().
        var amaster: Int32 = -1
        var aslave: Int32 = -1
        let openResult: Int32
        if var slaveAttributes = slaveTerminalAttributes {
            openResult = withUnsafeMutablePointer(to: &slaveAttributes) { attributesPointer in
                openpty(&amaster, &aslave, nil, attributesPointer, &winSize)
            }
        } else {
            openResult = openpty(&amaster, &aslave, nil, nil, &winSize)
        }
        guard openResult == 0 else {
            throw PTYError.forkptyFailed("openpty failed: \(String(cString: strerror(errno)))")
        }

        // Set close-on-exec on master BEFORE fork — the entire point of this
        // refactor.  Future child processes will never inherit this fd.
        _ = fcntl(amaster, F_SETFD, FD_CLOEXEC)

        // ── Fork ───────────────────────────────────────────────────────────
        // Use pterm_fork_pty (C) because Swift/Foundation marks fork() as
        // unavailable.  The C function performs: fork → child: close(master),
        // setsid, TIOCSCTTY, dup2(slave,0/1/2), close(slave), close fds 3..rlimit.
        // In the parent it closes the slave fd.
        let pid = pterm_fork_pty(amaster, aslave)

        if pid < 0 {
            close(amaster)
            close(aslave)
            throw PTYError.forkptyFailed("fork failed: \(String(cString: strerror(errno)))")
        }

        if pid == 0 {
            // ── Child process (returned from pterm_fork_pty) ───────────────
            // stdio is already connected to slave; all fds >= 3 are closed.
            setupChildEnvironment(shellPath: resolvedShellPath, termEnv: safeTerm, initialDirectory: initialDirectory)
            if let resolvedExecutablePath {
                let argv = Self.makeExecArguments(
                    executablePath: resolvedExecutablePath,
                    arguments: arguments
                )
                execv(resolvedExecutablePath, argv)
                for ptr in argv {
                    if let ptr { free(ptr) }
                }
            } else {
                let argv: [UnsafeMutablePointer<CChar>?] = [
                    strdup(resolvedShellPath),
                    strdup("--login"),
                    nil
                ]
                execv(resolvedShellPath, argv)
                for ptr in argv {
                    if let ptr { free(ptr) }
                }
            }
            _exit(1)
        }

        // ── Parent process ─────────────────────────────────────────────────
        // pterm_fork_pty already closed slave in the parent.
        fdLock.lock()
        self.masterFD = amaster
        self._isRunning = true
        fdLock.unlock()

        self.childPID = pid
        resetExitState()

        // Set non-blocking mode
        let flags = fcntl(amaster, F_GETFL)
        _ = fcntl(amaster, F_SETFL, flags | O_NONBLOCK)

        // Set up dispatch source for reading
        let source = DispatchSource.makeReadSource(fileDescriptor: amaster,
                                                    queue: Self.readQueue)
        source.setEventHandler { [weak self] in
            self?.handleReadEvent()
        }
        // Cancel handler: no FD close here — stop() is the sole owner of close
        source.setCancelHandler { /* intentionally empty */ }
        self.readSource = source
        source.resume()

        // Monitor child process exit
        monitorChildExit()
    }

    /// Stop the PTY and terminate the child process.
    func stop(waitForExit: Bool = false) {
        initiateShutdown()
        if waitForExit {
            awaitExit()
        } else {
            // Escalate to SIGKILL asynchronously if SIGTERM is not honoured.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.awaitExit()
            }
        }
    }

    /// Phase 1: Send SIGTERM and close the PTY file descriptor.
    /// Safe to call multiple times. Does not block.
    func initiateShutdown() {
        // Cancel dispatch source first to prevent further read events
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        releaseReadBuffer()
        Self.writeQueue.sync {
            pendingHighPriorityWrites.removeAll(keepingCapacity: false)
            pendingRegularWrites.removeAll(keepingCapacity: false)
            activeHighPriorityWrite = nil
            activeRegularWrite = nil
        }

        // Close FD under lock — single close site prevents double-close
        fdLock.lock()
        let fd = masterFD
        let pid = childPID
        masterFD = -1
        _isRunning = false
        fdLock.unlock()

        if fd >= 0 {
            close(fd)
        }

        if pid > 0 {
            kill(pid, SIGTERM)
        }
    }

    /// Phase 2: Wait for the child process to exit.
    /// If SIGTERM is not honoured within 0.5s, escalates to SIGKILL.
    func awaitExit() {
        fdLock.lock()
        let pid = childPID
        fdLock.unlock()

        guard pid > 0 else { return }

        if exitSemaphore.wait(timeout: .now() + 0.5) == .timedOut {
            kill(pid, SIGKILL)
            _ = exitSemaphore.wait(timeout: .now() + 2.0)
        }
    }

    /// Wait indefinitely for the child process to exit without forcing termination.
    func waitForExit() {
        fdLock.lock()
        let pid = childPID
        fdLock.unlock()

        guard pid > 0 else { return }
        exitSemaphore.wait()
    }

    /// Write data to the PTY (user input).
    func write(_ data: Data) {
        enqueueWrite(data, highPriority: false)
    }

    /// Write terminal protocol responses back to the child process.
    /// Responses must preserve ordering and should not be delayed behind
    /// regular user-input writes, since queries such as DSR/DA can be
    /// latency-sensitive.
    func writeResponse(_ data: Data) {
        enqueueWrite(data, highPriority: true)
    }

    /// Write a string to the PTY.
    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        write(data)
    }

    func writeControlCharacter(_ byte: UInt8) {
        fdLock.lock()
        let fd = masterFD
        fdLock.unlock()

        guard fd >= 0 else { return }
        enqueueWrite(Data([byte]), highPriority: true)
    }

    func sendEndOfTransmission() {
        writeControlCharacter(ControlCharacter.endOfTransmission)
    }

    /// Returns the current foreground process group leader PID for this PTY.
    /// When the shell is waiting for input, this is typically the shell PID.
    func foregroundProcessGroupID() -> pid_t? {
        fdLock.lock()
        let fd = masterFD
        fdLock.unlock()

        guard fd >= 0 else { return nil }
        let pgid = tcgetpgrp(fd)
        guard pgid > 0 else { return nil }
        return pgid
    }

    /// Update terminal size and notify the child process via SIGWINCH.
    func resize(rows: UInt16, cols: UInt16) {
        termRows = rows
        termCols = cols

        fdLock.lock()
        let fd = masterFD
        fdLock.unlock()

        guard fd >= 0 else { return }

        var winSize = winsize(
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        _ = ioctl(fd, TIOCSWINSZ, &winSize)

        if childPID > 0 {
            kill(childPID, SIGWINCH)
        }
    }

    // MARK: - Private

    /// Resolve the shell binary to execute from the configured launch order.
    static func resolveShellPath(
        launchOrder: [String],
        userShellPath: String?,
        isExecutable: (String) -> Bool
    ) -> String? {
        for candidate in ShellLaunchConfiguration.normalizedLaunchOrder(launchOrder) {
            if isExecutable(candidate) {
                return candidate
            }
        }
        if let userShellPath,
           !userShellPath.isEmpty,
           isExecutable(userShellPath) {
            return userShellPath
        }
        return nil
    }

    static func resolveExecutablePath(
        _ executablePath: String,
        isExecutable: (String) -> Bool
    ) -> String? {
        let trimmed = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            return nil
        }

        let normalized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        guard isExecutable(normalized) else {
            return nil
        }
        return normalized
    }

    private func resolvedUserShellPath() -> String? {
        let userInfo = getpwuid(getuid())
        return userInfo.flatMap { String(validatingUTF8: $0.pointee.pw_shell) }
    }

    private static func makeExecArguments(
        executablePath: String,
        arguments: [String]
    ) -> [UnsafeMutablePointer<CChar>?] {
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executablePath)]
        argv.reserveCapacity(arguments.count + 2)
        for argument in arguments {
            argv.append(strdup(argument))
        }
        argv.append(nil)
        return argv
    }

    private func setupChildEnvironment(shellPath: String, termEnv: String, initialDirectory: String?) {
        let userInfo = getpwuid(getuid())
        let fallbackHome = FileManager.default.homeDirectoryForCurrentUser.path
        let homeDirectory = userInfo.flatMap { String(validatingUTF8: $0.pointee.pw_dir) }
            ?? fallbackHome
        let userName = userInfo.flatMap { String(validatingUTF8: $0.pointee.pw_name) }
            ?? NSUserName()

        clearInheritedEnvironment()

        // Essential POSIX environment
        setenv("HOME", homeDirectory, 1)
        setenv("USER", userName, 1)
        setenv("LOGNAME", userName, 1)
        setenv("SHELL", shellPath, 1)
        setenv("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1)
        setenv("TMPDIR", NSTemporaryDirectory(), 1)

        // Terminal identification
        setenv("TERM", termEnv, 1)
        setenv("COLORTERM", "truecolor", 1)

        // Locale
        setenv("LANG", "en_US.UTF-8", 1)

        let targetDirectory = initialDirectory
            .flatMap { ($0 as NSString).expandingTildeInPath }
            ?? homeDirectory
        if chdir(targetDirectory) != 0 {
            _exit(1)
        }
    }

    private func clearInheritedEnvironment() {
        for key in ProcessInfo.processInfo.environment.keys {
            unsetenv(key)
        }
    }

    private func handleReadEvent() {
        fdLock.lock()
        let fd = masterFD
        fdLock.unlock()

        guard fd >= 0 else { return }

        let bufferCapacity = preparedReadBufferCapacity()
        guard let aggregatedReadBuffer = preparedReadBufferPointer() else {
            fatalError("Failed to allocate PTY read buffer")
        }
        var aggregatedCount = 0

        while aggregatedCount < ReadBufferPolicy.maximumBatchBytes {
            let remainingCapacity = min(
                bufferCapacity,
                ReadBufferPolicy.maximumBatchBytes - aggregatedCount
            )
            let destination = aggregatedReadBuffer.advanced(by: aggregatedCount)
            let bytesRead = read(fd, destination, remainingCapacity)
            if bytesRead > 0 {
                aggregatedCount += bytesRead
                continue
            }

            if bytesRead == 0 {
                fdLock.lock()
                _isRunning = false
                fdLock.unlock()
                if aggregatedCount > 0 {
                    emitOutput(buffer: aggregatedReadBuffer, count: aggregatedCount)
                }
                releaseReadBuffer()
                markReadChannelClosedAndNotifyIfReady()
                return
            }

            if bytesRead < 0 && errno != EAGAIN && errno != EINTR {
                fdLock.lock()
                _isRunning = false
                fdLock.unlock()
                if aggregatedCount > 0 {
                    emitOutput(buffer: aggregatedReadBuffer, count: aggregatedCount)
                }
                releaseReadBuffer()
                markReadChannelClosedAndNotifyIfReady()
                return
            }

            if bytesRead < 0 && errno == EINTR {
                continue
            }
            break
        }

        if aggregatedCount > 0 {
            emitOutput(buffer: aggregatedReadBuffer, count: aggregatedCount)
        }
    }

    private func preparedReadBufferPointer() -> UnsafeMutablePointer<UInt8>? {
        readBufferLock.lock()
        defer { readBufferLock.unlock() }
        ensureReadBufferCapacityLocked(ReadBufferPolicy.maximumBatchBytes)
        return readBuffer
    }

    private func preparedReadBufferCapacity() -> Int {
        readBufferLock.lock()
        defer { readBufferLock.unlock() }
        ensureReadBufferCapacityLocked(ReadBufferPolicy.maximumBatchBytes)
        return readBufferCapacity
    }

    private func shrinkIdleReadBufferIfNeeded() {
        readBufferLock.lock()
        defer { readBufferLock.unlock() }
        releaseReadBufferLocked()
    }

    private func releaseReadBuffer() {
        readBufferLock.lock()
        releaseReadBufferLocked()
        readBufferLock.unlock()
    }

    private func ensureReadBufferCapacityLocked(_ capacity: Int) {
        if readBufferCapacity == capacity, readBuffer != nil {
            return
        }
        releaseReadBufferLocked()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        readBuffer = buffer
        readBufferCapacity = capacity
    }

    private func releaseReadBufferLocked() {
        guard let readBuffer else { return }
        readBuffer.deallocate()
        self.readBuffer = nil
        readBufferCapacity = 0
    }

    private func emitOutput(buffer: UnsafeMutablePointer<UInt8>, count: Int) {
        let bytes = UnsafeBufferPointer(start: buffer, count: count)
        if let onOutputBytes {
            onOutputBytes(bytes)
            return
        }
        aggregatedReadData.removeAll(keepingCapacity: true)
        aggregatedReadData.append(buffer, count: count)
        onOutput?(aggregatedReadData)
    }

    private func monitorChildExit() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var status: Int32 = 0
            let pid = self.childPID
            guard pid > 0 else { return }
            waitpid(pid, &status, 0)
            self.exitStateLock.lock()
            self.childTerminationStatus = status
            self.exitStateLock.unlock()
            self.fdLock.lock()
            self._isRunning = false
            self.childPID = 0
            self.fdLock.unlock()
            self.exitSemaphore.signal()
            self.markChildExitObservedAndNotifyIfReady()
        }
    }

    private func resetExitState() {
        exitStateLock.lock()
        childExitObserved = false
        readChannelClosed = false
        exitNotified = false
        childTerminationStatus = nil
        exitStateLock.unlock()
    }

    private func markReadChannelClosedAndNotifyIfReady() {
        exitStateLock.lock()
        readChannelClosed = true
        let shouldNotify = childExitObserved && !exitNotified
        if shouldNotify {
            exitNotified = true
        }
        exitStateLock.unlock()

        if shouldNotify {
            DispatchQueue.main.async { [weak self] in
                self?.onExit?()
            }
        }
    }

    private func markChildExitObservedAndNotifyIfReady() {
        exitStateLock.lock()
        childExitObserved = true
        fdLock.lock()
        let fdClosed = masterFD < 0
        let readSourceGone = readSource == nil
        fdLock.unlock()
        let shouldNotify = (readChannelClosed || fdClosed || readSourceGone) && !exitNotified
        if shouldNotify {
            exitNotified = true
        }
        exitStateLock.unlock()

        if shouldNotify {
            DispatchQueue.main.async { [weak self] in
                self?.onExit?()
            }
        }
    }

    private func enqueueWrite(_ data: Data, highPriority: Bool) {
        guard !data.isEmpty else { return }
        Self.writeQueue.async { [weak self] in
            guard let self else { return }
            let pending = PendingWrite(data: data)
            if highPriority {
                self.pendingHighPriorityWrites.append(pending)
            } else {
                self.pendingRegularWrites.append(pending)
            }
            self.drainPendingWrites()
        }
    }

    private func drainPendingWrites() {
        guard currentMasterFD() >= 0 else {
            disarmWriteSource()
            return
        }

        while true {
            let isHighPriority = prepareNextWriteIfNeeded()
            guard let pendingWrite = currentPendingWrite(isHighPriority: isHighPriority) else {
                disarmWriteSource()
                return
            }

            let result = pendingWrite.data.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(
                    currentMasterFD(),
                    baseAddress + pendingWrite.offset,
                    pendingWrite.remainingByteCount
                )
            }

            if result > 0 {
                advanceCurrentWrite(isHighPriority: isHighPriority, bytesWritten: result)
                continue
            }

            if result == 0 {
                armWriteSourceIfNeeded()
                return
            }

            switch errno {
            case EINTR:
                continue
            case EAGAIN:
                armWriteSourceIfNeeded()
                return
            default:
                clearPendingWrites()
                disarmWriteSource()
                return
            }
        }
    }

    private func armWriteSourceIfNeeded() {
        guard currentMasterFD() >= 0, writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(
            fileDescriptor: currentMasterFD(),
            queue: Self.writeQueue
        )
        source.setEventHandler { [weak self] in
            self?.drainPendingWrites()
        }
        source.setCancelHandler { /* intentionally empty */ }
        writeSource = source
        source.resume()
    }

    private func disarmWriteSource() {
        guard let source = writeSource else { return }
        writeSource = nil
        source.cancel()
    }

    private func prepareNextWriteIfNeeded() -> Bool {
        if activeHighPriorityWrite == nil, !pendingHighPriorityWrites.isEmpty {
            activeHighPriorityWrite = pendingHighPriorityWrites.removeFirst()
        }
        if activeHighPriorityWrite != nil {
            return true
        }
        if activeRegularWrite == nil, !pendingRegularWrites.isEmpty {
            activeRegularWrite = pendingRegularWrites.removeFirst()
        }
        return false
    }

    private func currentPendingWrite(isHighPriority: Bool) -> PendingWrite? {
        isHighPriority ? activeHighPriorityWrite : activeRegularWrite
    }

    private func advanceCurrentWrite(isHighPriority: Bool, bytesWritten: Int) {
        if isHighPriority {
            guard var write = activeHighPriorityWrite else { return }
            write.offset += bytesWritten
            activeHighPriorityWrite = write.remainingByteCount == 0 ? nil : write
        } else {
            guard var write = activeRegularWrite else { return }
            write.offset += bytesWritten
            activeRegularWrite = write.remainingByteCount == 0 ? nil : write
        }
    }

    private func clearPendingWrites() {
        pendingHighPriorityWrites.removeAll(keepingCapacity: false)
        pendingRegularWrites.removeAll(keepingCapacity: false)
        activeHighPriorityWrite = nil
        activeRegularWrite = nil
    }

    private func currentMasterFD() -> Int32 {
        fdLock.lock()
        defer { fdLock.unlock() }
        return masterFD
    }

    private static func waitStatusCode(_ status: Int32) -> Int32 {
        status & 0x7f
    }

    private static func didExitNormally(_ status: Int32) -> Bool {
        waitStatusCode(status) == 0
    }

    private static func wasTerminatedBySignal(_ status: Int32) -> Bool {
        let code = waitStatusCode(status)
        return code != 0 && code != 0x7f
    }

    private static func exitStatus(_ status: Int32) -> Int32 {
        (status >> 8) & 0xff
    }

    private static func terminationSignal(_ status: Int32) -> Int32 {
        waitStatusCode(status)
    }
}

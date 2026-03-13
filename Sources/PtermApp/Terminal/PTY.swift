import Foundation
import PtermCore
import Darwin

/// Error type for PTY operations.
enum PTYError: Error {
    case forkptyFailed(String)
}

/// Manages a pseudo-terminal (PTY) for communicating with a child shell process.
///
/// Creates a PTY pair via forkpty(), spawns zsh as the child process,
/// and provides non-blocking I/O for reading output and writing input.
///
/// Thread safety: All access to masterFD and isRunning is protected by fdLock
/// to prevent data races between the GCD read source and stop()/write() calls.
final class PTY {
    private enum ReadBufferPolicy {
        static let minimumCapacity = 4096
        static let preferredCapacity = 16384
    }

    /// File descriptor of the PTY master side
    private var masterFD: Int32 = -1

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

    /// Signals that the child process has fully exited and been reaped.
    private let exitSemaphore = DispatchSemaphore(value: 0)

    /// Reusable read buffer to avoid allocating a fresh 16KB array on every PTY event.
    private var readBuffer: [UInt8] = []
    private let readBufferLock = NSLock()

    /// Callback invoked when data is available from the PTY
    var onOutput: ((Data) -> Void)?

    /// Callback invoked when the child process exits
    var onExit: (() -> Void)?

    /// Terminal size (rows x cols)
    private var termRows: UInt16 = 24
    private var termCols: UInt16 = 80

    deinit {
        stop()
    }

    var debugReadBufferCapacity: Int {
        readBufferLock.lock()
        defer { readBufferLock.unlock() }
        return readBuffer.count
    }

    func debugPrimeReadBufferCapacity(_ capacity: Int) {
        readBufferLock.lock()
        defer { readBufferLock.unlock() }
        let normalized = max(ReadBufferPolicy.minimumCapacity, capacity)
        readBuffer = [UInt8](repeating: 0, count: normalized)
    }

    func debugShrinkIdleReadBufferNow() {
        shrinkIdleReadBufferIfNeeded()
    }

    /// Start the PTY with the specified terminal size.
    /// Spawns zsh as the child process.
    /// Throws PTYError.forkptyFailed if forkpty() fails.
    func start(rows: UInt16, cols: UInt16, termEnv: String = "xterm-256color",
               initialDirectory: String? = nil) throws {
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

        var amaster: Int32 = -1
        let pid = forkpty(&amaster, nil, nil, &winSize)

        if pid < 0 {
            throw PTYError.forkptyFailed(String(cString: strerror(errno)))
        }

        if pid == 0 {
            // Child process: exec zsh
            setupChildEnvironment(termEnv: safeTerm, initialDirectory: initialDirectory)
            let shell = "/bin/zsh"
            let argv: [UnsafeMutablePointer<CChar>?] = [
                strdup(shell),
                strdup("--login"),
                nil
            ]
            execv(shell, argv)
            // If execv returns, it failed
            _exit(1)
        }

        // Parent process
        fdLock.lock()
        self.masterFD = amaster
        self._isRunning = true
        fdLock.unlock()

        self.childPID = pid

        // Set non-blocking mode
        let flags = fcntl(amaster, F_GETFL)
        _ = fcntl(amaster, F_SETFL, flags | O_NONBLOCK)

        // Set up dispatch source for reading
        let source = DispatchSource.makeReadSource(fileDescriptor: amaster,
                                                    queue: .global(qos: .userInteractive))
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
        releaseReadBuffer()

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

    /// Write data to the PTY (user input).
    func write(_ data: Data) {
        fdLock.lock()
        let fd = masterFD
        fdLock.unlock()

        guard fd >= 0 else { return }
        data.withUnsafeBytes { ptr in
            guard let baseAddr = ptr.baseAddress else { return }
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, baseAddr + offset, remaining)
                if written < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    break
                }
                offset += written
                remaining -= written
            }
        }
    }

    /// Write a string to the PTY.
    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        write(data)
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

    private func setupChildEnvironment(termEnv: String, initialDirectory: String?) {
        let userInfo = getpwuid(getuid())
        let fallbackHome = FileManager.default.homeDirectoryForCurrentUser.path
        let homeDirectory = userInfo.flatMap { String(validatingUTF8: $0.pointee.pw_dir) }
            ?? fallbackHome
        let userName = userInfo.flatMap { String(validatingUTF8: $0.pointee.pw_name) }
            ?? NSUserName()
        let userShell = userInfo.flatMap { String(validatingUTF8: $0.pointee.pw_shell) }
            ?? "/bin/zsh"

        clearInheritedEnvironment()

        // Essential POSIX environment
        setenv("HOME", homeDirectory, 1)
        setenv("USER", userName, 1)
        setenv("LOGNAME", userName, 1)
        setenv("SHELL", userShell, 1)
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

        var buffer = preparedReadBuffer()
        let bytesRead = read(fd, &buffer, buffer.count)
        storeReadBuffer(buffer)

        if bytesRead > 0 {
            let data = Data(buffer[0..<bytesRead])
            onOutput?(data)
            shrinkIdleReadBufferIfNeeded()
        } else if bytesRead == 0 || (bytesRead < 0 && errno != EAGAIN) {
            fdLock.lock()
            _isRunning = false
            fdLock.unlock()
            releaseReadBuffer()
            DispatchQueue.main.async { [weak self] in
                self?.onExit?()
            }
        }
    }

    private func preparedReadBuffer() -> [UInt8] {
        readBufferLock.lock()
        defer { readBufferLock.unlock() }
        if readBuffer.isEmpty {
            readBuffer = [UInt8](repeating: 0, count: ReadBufferPolicy.preferredCapacity)
        }
        return readBuffer
    }

    private func storeReadBuffer(_ buffer: [UInt8]) {
        readBufferLock.lock()
        readBuffer = buffer
        readBufferLock.unlock()
    }

    private func shrinkIdleReadBufferIfNeeded() {
        readBufferLock.lock()
        defer { readBufferLock.unlock() }
        guard !readBuffer.isEmpty else { return }
        readBuffer.removeAll(keepingCapacity: false)
    }

    private func releaseReadBuffer() {
        readBufferLock.lock()
        readBuffer.removeAll(keepingCapacity: false)
        readBufferLock.unlock()
    }

    private func monitorChildExit() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var status: Int32 = 0
            let pid = self.childPID
            guard pid > 0 else { return }
            waitpid(pid, &status, 0)
            self.fdLock.lock()
            self._isRunning = false
            self.childPID = 0
            self.fdLock.unlock()
            self.exitSemaphore.signal()
            DispatchQueue.main.async {
                self.onExit?()
            }
        }
    }
}

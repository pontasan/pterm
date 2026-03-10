import Foundation
import PtermCore

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

    /// Start the PTY with the specified terminal size.
    /// Spawns zsh as the child process.
    /// Throws PTYError.forkptyFailed if forkpty() fails.
    func start(rows: UInt16, cols: UInt16, termEnv: String = "xterm-256color") throws {
        // Validate TERM value: only allow alphanumeric and hyphens
        let validTerm = termEnv.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
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
            setupChildEnvironment(termEnv: safeTerm)
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
    func stop() {
        // Cancel dispatch source first to prevent further read events
        readSource?.cancel()
        readSource = nil

        // Close FD under lock — single close site prevents double-close
        fdLock.lock()
        let fd = masterFD
        masterFD = -1
        _isRunning = false
        fdLock.unlock()

        if fd >= 0 {
            close(fd)
        }

        if childPID > 0 {
            kill(childPID, SIGTERM)
            let pid = childPID
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == 0 {
                    kill(pid, SIGKILL)
                    waitpid(pid, &status, 0)
                }
            }
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

    private func setupChildEnvironment(termEnv: String) {
        setenv("TERM", termEnv, 1)
        setenv("COLORTERM", "truecolor", 1)
        setenv("LANG", "en_US.UTF-8", 1)

        // Remove environment variables inherited from parent process that
        // could confuse child programs (e.g., Claude Code session detection).
        // pterm is an independent terminal — child shells must start clean.
        unsetenv("CLAUDECODE")
        unsetenv("CLAUDE_CODE_ENTRYPOINT")
        unsetenv("CLAUDE_CODE_SESSION_ACCESS_TOKEN")
    }

    private func handleReadEvent() {
        fdLock.lock()
        let fd = masterFD
        fdLock.unlock()

        guard fd >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 16384)
        let bytesRead = read(fd, &buffer, buffer.count)

        if bytesRead > 0 {
            let data = Data(buffer[0..<bytesRead])
            onOutput?(data)
        } else if bytesRead == 0 || (bytesRead < 0 && errno != EAGAIN) {
            fdLock.lock()
            _isRunning = false
            fdLock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.onExit?()
            }
        }
    }

    private func monitorChildExit() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var status: Int32 = 0
            waitpid(self.childPID, &status, 0)
            self.fdLock.lock()
            self._isRunning = false
            self.fdLock.unlock()
            DispatchQueue.main.async {
                self.onExit?()
            }
        }
    }
}

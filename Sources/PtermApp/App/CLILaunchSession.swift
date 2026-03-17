import Foundation
import Darwin
import PtermCore

private final class CLIEmulatorBridge {
    private let lock = NSLock()
    private let model: TerminalModel
    private var parser = VtParser()
    private var textDecoder: TerminalTextDecoder
    private var codepointBuffer: [UInt32] = []

    init(rows: Int,
         cols: Int,
         textEncoding: TerminalTextEncoding,
         responseWriter: @escaping (Data) -> Void) {
        model = TerminalModel(rows: rows, cols: cols)
        textDecoder = TerminalTextDecoder(encoding: textEncoding)
        model.onResponseData = { data in
            responseWriter(data)
        }
        model.onResponse = { response in
            guard let data = textEncoding.encode(response) else { return }
            responseWriter(data)
        }
        model.encodeText = { textEncoding.encode($0) }
        model.decodeText = { textEncoding.decode($0) }

        vt_parser_init(&parser, { parserPtr, action, codepoint, userData in
            guard let parserPtr, let userData else { return }
            let bridge = Unmanaged<CLIEmulatorBridge>.fromOpaque(userData).takeUnretainedValue()
            bridge.model.handleAction(action, codepoint: codepoint, parser: parserPtr)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        vt_parser_destroy(&parser)
    }

    func resize(rows: Int, cols: Int) {
        lock.lock()
        defer { lock.unlock() }
        model.resize(newRows: rows, newCols: cols)
    }

    func consume(_ input: UnsafeBufferPointer<UInt8>) {
        guard !input.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        if codepointBuffer.count < input.count {
            codepointBuffer = [UInt32](repeating: 0, count: input.count)
        }

        let codepointCount = textDecoder.decode(input, into: &codepointBuffer)
        guard codepointCount > 0 else { return }

        codepointBuffer.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            vt_parser_feed(&parser, baseAddress, codepointCount)
        }
    }
}

private final class CLITerminalOutputFilter {
    private var pending = Data()

    func filter(_ input: UnsafeBufferPointer<UInt8>) -> Data {
        guard !input.isEmpty else { return Data() }

        var source = Data()
        source.reserveCapacity(pending.count + input.count)
        if !pending.isEmpty {
            source.append(pending)
            pending.removeAll(keepingCapacity: true)
        }
        source.append(input.baseAddress!, count: input.count)

        var output = Data()
        output.reserveCapacity(source.count)

        let bytes = [UInt8](source)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]

            if byte == 0x05 {
                index += 1
                continue
            }

            guard byte == 0x1B else {
                output.append(byte)
                index += 1
                continue
            }

            guard index + 1 < bytes.count else {
                pending.append(contentsOf: bytes[index...])
                break
            }

            let next = bytes[index + 1]
            switch next {
            case UInt8(ascii: "Z"):
                index += 2

            case UInt8(ascii: "["):
                if let endIndex = findCSITerminator(in: bytes, startingAt: index + 2) {
                    let finalByte = bytes[endIndex]
                    if finalByte == UInt8(ascii: "c")
                        || finalByte == UInt8(ascii: "n")
                        || finalByte == UInt8(ascii: "x") {
                        index = endIndex + 1
                    } else {
                        output.append(contentsOf: bytes[index...endIndex])
                        index = endIndex + 1
                    }
                } else {
                    pending.append(contentsOf: bytes[index...])
                    index = bytes.count
                }

            case UInt8(ascii: "P"):
                if let endIndex = findStringTerminator(in: bytes, startingAt: index + 2) {
                    index = endIndex
                } else {
                    pending.append(contentsOf: bytes[index...])
                    index = bytes.count
                }

            default:
                output.append(byte)
                index += 1
            }
        }

        return output
    }

    private func findCSITerminator(in bytes: [UInt8], startingAt start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= 0x40 && byte <= 0x7E {
                return index
            }
            index += 1
        }
        return nil
    }

    private func findStringTerminator(in bytes: [UInt8], startingAt start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x07 {
                return index + 1
            }
            if byte == 0x1B {
                guard index + 1 < bytes.count else { return nil }
                if bytes[index + 1] == UInt8(ascii: "\\") {
                    return index + 2
                }
            }
            index += 1
        }
        return nil
    }
}

final class CLILaunchSession {
    private let launchOptions: LaunchOptions
    private let config: PtermConfig
    private let pty = PTY()
    private let stdinQueue = DispatchQueue(label: "com.pterm.cli.stdin", qos: .userInteractive)
    private let stateLock = NSLock()
    private var stdinReadSource: DispatchSourceRead?
    private var sigwinchSource: DispatchSourceSignal?
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var exitCode: Int32 = EXIT_FAILURE
    private var standardInputWasTTY = false
    private var savedTerminalAttributes: termios?
    private var hasFinished = false
    private var forwardedStandardInputBytes = false
    private var emulatorBridge: CLIEmulatorBridge?
    private let outputFilter = CLITerminalOutputFilter()

    init(launchOptions: LaunchOptions, config: PtermConfig) {
        self.launchOptions = launchOptions
        self.config = config
    }

    func run() throws {
        try configureTerminalInput()

        let initialSize = currentTerminalSize()
        let initialDirectory = FileManager.default.currentDirectoryPath
        let directLaunch = launchOptions.directLaunch
        let textEncoding = config.textEncoding

        emulatorBridge = CLIEmulatorBridge(
            rows: Int(initialSize.rows),
            cols: Int(initialSize.cols),
            textEncoding: textEncoding,
            responseWriter: { [weak self] data in
                self?.pty.writeResponse(data)
            }
        )

        pty.onOutputBytes = { bytes in
            self.emulatorBridge?.consume(bytes)
            let filtered = self.outputFilter.filter(bytes)
            filtered.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                Self.writeAll(to: STDOUT_FILENO,
                              bytes: UnsafeBufferPointer(start: baseAddress, count: filtered.count))
            }
        }

        try pty.start(
            rows: initialSize.rows,
            cols: initialSize.cols,
            termEnv: config.term,
            initialDirectory: initialDirectory,
            shellLaunchOrder: config.shellLaunch.launchOrder,
            slaveTerminalAttributes: savedTerminalAttributes,
            executablePath: directLaunch?.executablePath,
            arguments: directLaunch?.arguments ?? []
        )

        installSTDINBridge()
        installWindowResizeBridge()
        installTerminationSignalHandlers()
        monitorProcessExit()

        dispatchMain()
    }

    private func configureTerminalInput() throws {
        standardInputWasTTY = isatty(STDIN_FILENO) == 1
        guard standardInputWasTTY else { return }

        var attributes = termios()
        guard tcgetattr(STDIN_FILENO, &attributes) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        savedTerminalAttributes = attributes

        var rawAttributes = attributes
        cfmakeraw(&rawAttributes)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &rawAttributes) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func restoreTerminalInput() {
        guard standardInputWasTTY, var savedTerminalAttributes else { return }
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTerminalAttributes)
    }

    private func installSTDINBridge() {
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: stdinQueue)
        source.setEventHandler { [weak self] in
            self?.drainStandardInput()
        }
        source.setCancelHandler {}
        stdinReadSource = source
        source.resume()
    }

    private func drainStandardInput() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if bytesRead > 0 {
                forwardedStandardInputBytes = true
                pty.write(Data(buffer[..<bytesRead]))
                continue
            }
            if bytesRead == 0 {
                if forwardedStandardInputBytes {
                    pty.sendEndOfTransmission()
                }
                stdinReadSource?.cancel()
                stdinReadSource = nil
                return
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN {
                return
            }
            stdinReadSource?.cancel()
            stdinReadSource = nil
            return
        }
    }

    private func installWindowResizeBridge() {
        Darwin.signal(SIGWINCH, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let size = self.currentTerminalSize()
            self.emulatorBridge?.resize(rows: Int(size.rows), cols: Int(size.cols))
            self.pty.resize(rows: size.rows, cols: size.cols)
        }
        sigwinchSource = source
        source.resume()
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.pty.stop(waitForExit: false)
                self.finish(with: 128 + Int32(signalNumber))
            }
            terminationSignalSources.append(source)
            source.resume()
        }
    }

    private func monitorProcessExit() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.pty.waitForExit()
            DispatchQueue.main.async {
                self.finish(with: self.pty.normalizedExitCode)
            }
        }
    }

    private func stopEventSources() {
        stdinReadSource?.cancel()
        stdinReadSource = nil
        sigwinchSource?.cancel()
        sigwinchSource = nil
        for source in terminationSignalSources {
            source.cancel()
        }
        terminationSignalSources.removeAll(keepingCapacity: false)
    }

    private func finish(with exitCode: Int32) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !hasFinished else { return }
        hasFinished = true
        self.exitCode = exitCode
        stopEventSources()
        restoreTerminalInput()
        Darwin.exit(exitCode)
    }

    private func currentTerminalSize() -> (rows: UInt16, cols: UInt16) {
        var windowSize = winsize()
        for fileDescriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            if ioctl(fileDescriptor, TIOCGWINSZ, &windowSize) == 0,
               windowSize.ws_row > 0,
               windowSize.ws_col > 0 {
                return (rows: windowSize.ws_row, cols: windowSize.ws_col)
            }
        }
        return (rows: 24, cols: 80)
    }

    private static func writeAll(to fileDescriptor: Int32, bytes: UnsafeBufferPointer<UInt8>) {
        guard let baseAddress = bytes.baseAddress else { return }
        var remaining = bytes.count
        var current = baseAddress

        while remaining > 0 {
            let written = Darwin.write(fileDescriptor, current, remaining)
            if written > 0 {
                remaining -= written
                current += written
                continue
            }
            if written < 0 && errno == EINTR {
                continue
            }
            return
        }
    }
}

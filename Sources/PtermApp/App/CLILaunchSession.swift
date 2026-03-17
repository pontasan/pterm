import Foundation
import Darwin
import PtermCore

private final class CLIEmulatorBridge {
    private let lock = NSLock()
    private let model: TerminalModel
    private var parser = VtParser()
    private var textDecoder: TerminalTextDecoder
    private var codepointBuffer: [UInt32] = []
    private let textEncoding: TerminalTextEncoding

    init(rows: Int,
         cols: Int,
         textEncoding: TerminalTextEncoding,
         responseWriter: @escaping (Data) -> Void) {
        model = TerminalModel(rows: rows, cols: cols)
        textDecoder = TerminalTextDecoder(encoding: textEncoding)
        self.textEncoding = textEncoding
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

        var fastPathPointer = input.baseAddress!
        var fastPathRemainingCount = input.count

        while fastPathRemainingCount > 0 {
            let candidate = UnsafeBufferPointer(start: fastPathPointer, count: fastPathRemainingCount)

            if canUseDirectASCIIGroundFastPath(candidate) {
                let consumed = model.consumeGroundASCIIBytesFastPathPrefix(candidate)
                if consumed > 0 {
                    fastPathPointer = fastPathPointer.advanced(by: consumed)
                    fastPathRemainingCount -= consumed
                    continue
                }
            }

            let ignoredStringBytes = vt_parser_consume_ascii_ignored_string_fast_path(
                &parser,
                fastPathPointer,
                fastPathRemainingCount
            )
            if ignoredStringBytes > 0 {
                fastPathPointer = fastPathPointer.advanced(by: ignoredStringBytes)
                fastPathRemainingCount -= ignoredStringBytes
                continue
            }

            break
        }

        let remainingInput = UnsafeBufferPointer(start: fastPathPointer, count: fastPathRemainingCount)
        guard !remainingInput.isEmpty else { return }

        if codepointBuffer.count < remainingInput.count {
            codepointBuffer = [UInt32](repeating: 0, count: remainingInput.count)
        }

        let codepointCount = textDecoder.decode(remainingInput, into: &codepointBuffer)
        guard codepointCount > 0 else { return }

        codepointBuffer.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            if parser.state == VT_STATE_GROUND {
                let consumed = model.consumeGroundFastPathPrefix(
                    UnsafeBufferPointer(start: baseAddress, count: codepointCount)
                )
                if consumed < codepointCount {
                    vt_parser_feed(&parser, baseAddress.advanced(by: consumed), codepointCount - consumed)
                }
            } else {
                vt_parser_feed(&parser, baseAddress, codepointCount)
            }
        }
    }

    private func canUseDirectASCIIGroundFastPath(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !bytes.isEmpty,
              textEncoding == .utf8,
              textDecoder.canDecodeDirectASCII,
              parser.state == VT_STATE_GROUND,
              model.canUseASCIIGroundFastPath
        else {
            return false
        }

        return true
    }
}

final class CLITerminalOutputFilter {
    private static let pendingUpdateDisableSequence = Array("\u{1B}[?2026l".utf8)
    private var pending: [UInt8] = []
    private var synchronizedOutputSuppressed = false

    func filter(_ input: UnsafeBufferPointer<UInt8>) -> Data {
        guard !input.isEmpty else { return Data() }
        if pending.isEmpty {
            return process(input)
        }

        var combined = [UInt8]()
        combined.reserveCapacity(pending.count + input.count)
        combined.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        combined.append(contentsOf: input)
        return combined.withUnsafeBufferPointer(process)
    }

    private func process(_ bytes: UnsafeBufferPointer<UInt8>) -> Data {
        if synchronizedOutputSuppressed {
            return filterWhileSynchronizedOutputSuppressed(bytes)
        }

        var output = Data()
        output.reserveCapacity(bytes.count)

        var index = 0
        var passthroughStart = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte != 0x1B {
                index += 1
                continue
            }

            if passthroughStart < index {
                output.append(bytes.baseAddress!.advanced(by: passthroughStart), count: index - passthroughStart)
            }

            guard index + 1 < bytes.count else {
                pending.append(bytes[index])
                return output
            }

            let next = bytes[index + 1]
            switch next {
            case UInt8(ascii: "Z"):
                index += 2

            case UInt8(ascii: "["):
                guard let endIndex = findCSITerminator(in: bytes, startingAt: index + 2) else {
                    pending.append(contentsOf: UnsafeBufferPointer(start: bytes.baseAddress!.advanced(by: index), count: bytes.count - index))
                    return output
                }
                let finalByte = bytes[endIndex]
                if isPendingUpdateModeSequence(in: bytes, from: index, through: endIndex) {
                    synchronizedOutputSuppressed = finalByte == UInt8(ascii: "h")
                    index = endIndex + 1
                    if synchronizedOutputSuppressed {
                        passthroughStart = index
                        if index < bytes.count {
                            let suffix = filterWhileSynchronizedOutputSuppressed(
                                UnsafeBufferPointer(start: bytes.baseAddress!.advanced(by: index), count: bytes.count - index)
                            )
                            if !suffix.isEmpty {
                                output.append(suffix)
                            }
                        }
                        return output
                    }
                } else if finalByte == UInt8(ascii: "c")
                    || finalByte == UInt8(ascii: "n")
                    || finalByte == UInt8(ascii: "x") {
                    index = endIndex + 1
                } else if !synchronizedOutputSuppressed {
                    output.append(bytes.baseAddress!.advanced(by: index), count: endIndex - index + 1)
                    index = endIndex + 1
                } else {
                    index = endIndex + 1
                }

            case UInt8(ascii: "P"):
                guard let endIndex = findStringTerminator(in: bytes, startingAt: index + 2) else {
                    pending.append(contentsOf: UnsafeBufferPointer(start: bytes.baseAddress!.advanced(by: index), count: bytes.count - index))
                    return output
                }
                index = endIndex

            default:
                output.append(byte)
                index += 1
            }

            passthroughStart = index
        }

        if passthroughStart < bytes.count {
            output.append(bytes.baseAddress!.advanced(by: passthroughStart), count: bytes.count - passthroughStart)
        }

        return output
    }

    private func filterWhileSynchronizedOutputSuppressed(_ bytes: UnsafeBufferPointer<UInt8>) -> Data {
        guard !bytes.isEmpty else { return Data() }
        let resume = Self.pendingUpdateDisableSequence
        guard let baseAddress = bytes.baseAddress else { return Data() }
        var index = 0
        while index + resume.count <= bytes.count {
            let remaining = bytes.count - index
            guard let escPointer = memchr(baseAddress.advanced(by: index), Int32(0x1B), remaining) else {
                break
            }
            let escIndex = baseAddress.distance(to: escPointer.assumingMemoryBound(to: UInt8.self))
            guard escIndex + resume.count <= bytes.count else {
                index = escIndex
                break
            }

            var matched = true
            for offset in 0..<resume.count where bytes[escIndex + offset] != resume[offset] {
                matched = false
                break
            }
            if matched {
                synchronizedOutputSuppressed = false
                let suffixStart = escIndex + resume.count
                guard suffixStart < bytes.count else { return Data() }
                return process(
                    UnsafeBufferPointer(
                        start: baseAddress.advanced(by: suffixStart),
                        count: bytes.count - suffixStart
                    )
                )
            }
            index = escIndex + 1
        }

        let keepCount = min(resume.count - 1, bytes.count)
        if keepCount > 0 {
            pending.append(
                contentsOf: UnsafeBufferPointer(
                    start: baseAddress.advanced(by: bytes.count - keepCount),
                    count: keepCount
                )
            )
        }
        return Data()
    }

    private func findCSITerminator(in bytes: UnsafeBufferPointer<UInt8>, startingAt start: Int) -> Int? {
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

    private func findStringTerminator(in bytes: UnsafeBufferPointer<UInt8>, startingAt start: Int) -> Int? {
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

    private func isPendingUpdateModeSequence(
        in bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        through end: Int
    ) -> Bool {
        guard end == start + 7 else { return false }
        return bytes[start + 2] == UInt8(ascii: "?")
            && bytes[start + 3] == UInt8(ascii: "2")
            && bytes[start + 4] == UInt8(ascii: "0")
            && bytes[start + 5] == UInt8(ascii: "2")
            && bytes[start + 6] == UInt8(ascii: "6")
            && (bytes[end] == UInt8(ascii: "h") || bytes[end] == UInt8(ascii: "l"))
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
        pty.onExit = { [weak self] in
            guard let self else { return }
            self.finish(with: self.pty.normalizedExitCode)
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

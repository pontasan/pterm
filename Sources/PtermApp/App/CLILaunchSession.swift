import Foundation
import Darwin
import PtermCore

private func cliWriteAll(to fileDescriptor: Int32, bytes: UnsafeBufferPointer<UInt8>) {
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

private final class CLIEmulatorBridge {
    private struct DebugStats {
        var chunkCount = 0
        var totalBytes = 0
        var maxChunkBytes = 0
    }

    private let lock = NSLock()
    private let model: TerminalModel
    private var parser = VtParser()
    private var textDecoder: TerminalTextDecoder
    private var codepointBuffer: [UInt32] = []
    private var pendingGroundBytes: [UInt8] = []
    private let textEncoding: TerminalTextEncoding
    private let debugStatsEnabled = ProcessInfo.processInfo.environment["PTERM_DEBUG_CLI_STATS"] == "1"
    private var debugStats = DebugStats()

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

    func debugStatsSummary() -> String? {
        guard debugStatsEnabled else { return nil }
        return "pterm-cli-stats chunks=\(debugStats.chunkCount) total_bytes=\(debugStats.totalBytes) max_chunk=\(debugStats.maxChunkBytes)\n"
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

        if debugStatsEnabled {
            debugStats.chunkCount += 1
            debugStats.totalBytes += input.count
            if input.count > debugStats.maxChunkBytes {
                debugStats.maxChunkBytes = input.count
            }
        }

        let workingBufferStorage: [UInt8]?
        if pendingGroundBytes.isEmpty {
            workingBufferStorage = nil
        } else {
            var combined = pendingGroundBytes
            combined.reserveCapacity(combined.count + input.count)
            combined.append(contentsOf: input)
            pendingGroundBytes.removeAll(keepingCapacity: true)
            workingBufferStorage = combined
        }

        let processInput: (UnsafeBufferPointer<UInt8>) -> Void = { [self] workingInput in
            var fastPathPointer = workingInput.baseAddress!
            var fastPathRemainingCount = workingInput.count

            while fastPathRemainingCount > 0 {
                let candidate = UnsafeBufferPointer(start: fastPathPointer, count: fastPathRemainingCount)

                if self.canUseDirectASCIIGroundFastPath(candidate) {
                    let consumed = self.model.consumeGroundASCIIBytesFastPathPrefix(candidate)
                    if consumed > 0 {
                        fastPathPointer = fastPathPointer.advanced(by: consumed)
                        fastPathRemainingCount -= consumed
                        continue
                    }
                }

                let ignoredStringBytes = vt_parser_consume_ascii_ignored_string_fast_path(
                    &self.parser,
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
            if self.parser.state == VT_STATE_GROUND,
               self.shouldDeferIncompleteGroundSequence(remainingInput) {
                self.pendingGroundBytes = Array(remainingInput)
                return
            }
            guard !remainingInput.isEmpty else { return }

            if self.codepointBuffer.count < remainingInput.count {
                self.codepointBuffer = [UInt32](repeating: 0, count: remainingInput.count)
            }

            let codepointCount = self.textDecoder.decode(remainingInput, into: &self.codepointBuffer)
            guard codepointCount > 0 else { return }

            self.codepointBuffer.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                if self.parser.state == VT_STATE_GROUND {
                    let consumed = self.model.consumeGroundFastPathPrefix(
                        UnsafeBufferPointer(start: baseAddress, count: codepointCount)
                    )
                    if consumed < codepointCount {
                        vt_parser_feed(&self.parser, baseAddress.advanced(by: consumed), codepointCount - consumed)
                    }
                } else {
                    vt_parser_feed(&self.parser, baseAddress, codepointCount)
                }
            }
        }

        if let workingBufferStorage {
            workingBufferStorage.withUnsafeBufferPointer(processInput)
        } else {
            processInput(input)
        }
    }

    private func shouldDeferIncompleteGroundSequence(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = bytes.baseAddress,
              !bytes.isEmpty,
              bytes.count <= 64,
              bytes[0] == 0x1B
        else {
            return false
        }

        guard bytes.count >= 2 else { return true }
        let introducer = bytes[1]
        switch introducer {
        case UInt8(ascii: "["):
            guard bytes.count >= 3 else { return true }
            for index in 2..<bytes.count where bytes[index] >= 0x40 && bytes[index] <= 0x7E {
                return false
            }
            return true

        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            var index = 2
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x07 {
                    return false
                }
                if byte == 0x1B {
                    guard index + 1 < bytes.count else { return true }
                    if bytes[index + 1] == UInt8(ascii: "\\") {
                        return false
                    }
                }
                index += 1
            }
            return true

        case 0x37, 0x38, 0x44, 0x45, 0x48, 0x4D, 0x3D, 0x3E, 0x63:
            return false

        default:
            _ = base
            return bytes.count == 1
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
        let outputPipe = Pipe()
        writeFiltered(input, to: outputPipe.fileHandleForWriting.fileDescriptor)
        try? outputPipe.fileHandleForWriting.close()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        try? outputPipe.fileHandleForReading.close()
        return data
    }

    func writeFiltered(_ input: UnsafeBufferPointer<UInt8>, to fileDescriptor: Int32) {
        guard !input.isEmpty else { return }
        if pending.isEmpty {
            process(input, to: fileDescriptor)
            return
        }

        var combined = [UInt8]()
        combined.reserveCapacity(pending.count + input.count)
        combined.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        combined.append(contentsOf: input)
        combined.withUnsafeBufferPointer { buffer in
            process(buffer, to: fileDescriptor)
        }
    }

    private func process(_ bytes: UnsafeBufferPointer<UInt8>, to fileDescriptor: Int32) {
        if synchronizedOutputSuppressed {
            filterWhileSynchronizedOutputSuppressed(bytes, to: fileDescriptor)
            return
        }

        guard let baseAddress = bytes.baseAddress else { return }
        var index = 0
        while index < bytes.count {
            let remaining = bytes.count - index
            guard let escPointer = memchr(baseAddress.advanced(by: index), Int32(0x1B), remaining) else {
                cliWriteAll(
                    to: fileDescriptor,
                    bytes: UnsafeBufferPointer(
                        start: baseAddress.advanced(by: index),
                        count: remaining
                    )
                )
                return
            }

            let escIndex = baseAddress.distance(to: escPointer.assumingMemoryBound(to: UInt8.self))
            if index < escIndex {
                cliWriteAll(
                    to: fileDescriptor,
                    bytes: UnsafeBufferPointer(
                        start: baseAddress.advanced(by: index),
                        count: escIndex - index
                    )
                )
            }

            guard escIndex + 1 < bytes.count else {
                pending.append(0x1B)
                return
            }

            let next = bytes[escIndex + 1]
            switch next {
            case UInt8(ascii: "Z"):
                index = escIndex + 2

            case UInt8(ascii: "["):
                guard let endIndex = findCSITerminator(in: bytes, startingAt: escIndex + 2) else {
                    pending.append(
                        contentsOf: UnsafeBufferPointer(
                            start: baseAddress.advanced(by: escIndex),
                            count: bytes.count - escIndex
                        )
                    )
                    return
                }
                let finalByte = bytes[endIndex]
                if isPendingUpdateModeSequence(in: bytes, from: escIndex, through: endIndex) {
                    synchronizedOutputSuppressed = finalByte == UInt8(ascii: "h")
                    index = endIndex + 1
                    if synchronizedOutputSuppressed, index < bytes.count {
                        filterWhileSynchronizedOutputSuppressed(
                            UnsafeBufferPointer(
                                start: baseAddress.advanced(by: index),
                                count: bytes.count - index
                            ),
                            to: fileDescriptor
                        )
                        return
                    }
                } else if finalByte == UInt8(ascii: "c")
                    || finalByte == UInt8(ascii: "n")
                    || finalByte == UInt8(ascii: "x") {
                    index = endIndex + 1
                } else {
                    cliWriteAll(
                        to: fileDescriptor,
                        bytes: UnsafeBufferPointer(
                            start: baseAddress.advanced(by: escIndex),
                            count: endIndex - escIndex + 1
                        )
                    )
                    index = endIndex + 1
                }

            case UInt8(ascii: "P"):
                guard let endIndex = findStringTerminator(in: bytes, startingAt: escIndex + 2) else {
                    pending.append(
                        contentsOf: UnsafeBufferPointer(
                            start: baseAddress.advanced(by: escIndex),
                            count: bytes.count - escIndex
                        )
                    )
                    return
                }
                index = endIndex

            default:
                cliWriteAll(
                    to: fileDescriptor,
                    bytes: UnsafeBufferPointer(
                        start: baseAddress.advanced(by: escIndex),
                        count: 1
                    )
                )
                index = escIndex + 1
            }
        }
    }

    private func filterWhileSynchronizedOutputSuppressed(
        _ bytes: UnsafeBufferPointer<UInt8>,
        to fileDescriptor: Int32
    ) {
        guard !bytes.isEmpty else { return }
        let resume = Self.pendingUpdateDisableSequence
        guard let baseAddress = bytes.baseAddress else { return }
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
                guard suffixStart < bytes.count else { return }
                process(
                    UnsafeBufferPointer(
                        start: baseAddress.advanced(by: suffixStart),
                        count: bytes.count - suffixStart
                    ),
                    to: fileDescriptor
                )
                return
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
            self.outputFilter.writeFiltered(bytes, to: STDOUT_FILENO)
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
        if let summary = emulatorBridge?.debugStatsSummary() {
            FileHandle.standardError.write(Data(summary.utf8))
        }
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

}

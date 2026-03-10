import Foundation
import PtermCore

/// Coordinates PTY, VT parser, terminal model, and ring buffer.
///
/// This is the central controller for a single terminal session.
/// The PTY read thread writes to the ring buffer and feeds the VT parser.
/// The main thread reads the model for rendering.
///
/// Thread safety: All access to model, parser, and decoder is serialized
/// through `lock`. The PTY read thread acquires the lock for the entire
/// decode+parse operation.
final class TerminalController {
    /// Terminal model (grid + cursor + state)
    let model: TerminalModel

    /// PTY connection
    let pty: PTY

    /// VT parser (C struct)
    private var parser: VtParser = VtParser()

    /// UTF-8 decoder (C struct)
    private var decoder: Utf8Decoder = Utf8Decoder()

    /// Unique identifier
    let id: UUID = UUID()

    /// Terminal title (custom or from OSC)
    /// Thread-safe: accesses model under lock.
    var title: String {
        lock.lock()
        defer { lock.unlock() }
        return customTitle ?? (model.title.isEmpty ? currentDirectory : model.title)
    }

    /// User-set custom title (overrides OSC title)
    var customTitle: String?

    /// Current working directory
    private(set) var currentDirectory: String = "~"

    /// Whether this terminal is still alive
    var isAlive: Bool { pty.isRunning }

    /// Lock for thread-safe model/parser/decoder access
    private let lock = NSLock()

    /// Callback when terminal needs redraw
    var onNeedsDisplay: (() -> Void)?

    /// Callback when terminal exits
    var onExit: (() -> Void)?

    /// Callback when title changes
    var onTitleChange: ((String) -> Void)?

    /// Decode buffer for UTF-8 -> codepoints
    private var codepointBuffer = [UInt32](repeating: 0, count: 16384)

    init(rows: Int, cols: Int) {
        self.model = TerminalModel(rows: rows, cols: cols)
        self.pty = PTY()

        setupParser()
        setupModelCallbacks()
    }

    deinit {
        pty.stop()
        vt_parser_destroy(&parser)
    }

    // MARK: - Setup

    private func setupParser() {
        utf8_decoder_init(&decoder, true) // reject_c1 = true

        vt_parser_init(&parser, { parserPtr, action, codepoint, userData in
            guard let userData = userData else { return }
            let controller = Unmanaged<TerminalController>.fromOpaque(userData)
                .takeUnretainedValue()
            guard let parserPtr = parserPtr else { return }
            controller.model.handleAction(action, codepoint: codepoint,
                                          parser: parserPtr)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func setupModelCallbacks() {
        model.onTitleChange = { [weak self] title in
            DispatchQueue.main.async {
                self?.onTitleChange?(title)
            }
        }

        model.onResponse = { [weak self] data in
            guard let self = self else { return }
            // Queue write to avoid blocking model lock on I/O
            DispatchQueue.global(qos: .userInteractive).async {
                self.pty.write(data)
            }
        }

        model.onBell = {
            // TODO: handle bell (visual/audio based on config)
        }
    }

    // MARK: - Start / Stop

    func start(termEnv: String = "xterm-256color") throws {
        pty.onOutput = { [weak self] data in
            self?.handlePTYOutput(data)
        }

        pty.onExit = { [weak self] in
            self?.onExit?()
        }

        lock.lock()
        let r = model.rows
        let c = model.cols
        lock.unlock()

        try pty.start(rows: UInt16(r), cols: UInt16(c), termEnv: termEnv)
    }

    func stop() {
        pty.stop()
    }

    // MARK: - Input

    /// Send user keyboard input to the PTY.
    func sendInput(_ data: Data) {
        pty.write(data)
    }

    /// Send a string as input to the PTY.
    func sendInput(_ string: String) {
        pty.write(string)
    }

    // MARK: - PTY Output Processing

    /// Handle raw bytes from PTY output.
    /// Called on the PTY read thread - must be thread-safe.
    /// The entire decode + parse pipeline runs under lock to ensure
    /// decoder and parser state are never accessed concurrently.
    private func handlePTYOutput(_ data: Data) {
        data.withUnsafeBytes { rawPtr in
            guard let ptr = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            let count = rawPtr.count

            lock.lock()

            // Decode UTF-8 to codepoints
            let cpCount = utf8_decoder_decode(
                &decoder,
                ptr,
                count,
                &codepointBuffer,
                codepointBuffer.count
            )

            // Feed codepoints to VT parser (which updates the model)
            if cpCount > 0 {
                vt_parser_feed(&parser, codepointBuffer, cpCount)
            }

            lock.unlock()
        }

        // Request redraw on main thread
        DispatchQueue.main.async { [weak self] in
            self?.onNeedsDisplay?()
        }
    }

    // MARK: - Resize

    func resize(rows: Int, cols: Int) {
        lock.lock()
        model.resize(newRows: rows, newCols: cols)
        lock.unlock()

        pty.resize(rows: UInt16(rows), cols: UInt16(cols))
    }

    // MARK: - Thread-Safe Model Access

    /// Execute a block with read access to the terminal model.
    func withModel<T>(_ block: (TerminalModel) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block(model)
    }
}

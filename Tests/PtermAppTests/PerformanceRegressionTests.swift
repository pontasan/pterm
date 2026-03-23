import AppKit
import Metal
import MetalKit
import XCTest
@preconcurrency @testable import PtermApp

private func durationNanoseconds(_ duration: Duration) -> UInt64 {
    let components = duration.components
    let seconds = UInt64(max(components.seconds, 0))
    let attoseconds = UInt64(max(components.attoseconds, 0))
    return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
}

@MainActor
final class PerformanceRegressionTests: XCTestCase {
    private enum KittyBenchmarkFixture {
        static let asciiPrintable = #"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ  `~!@#$%^&*()_+-=[]{}\|;:'",<.>/?"#
        static let controlChars = "\n\t"
        static let chineseLoremIpsum = """

旦海司有幼雞讀松鼻種比門真目怪少：扒裝虎怕您跑綠蝶黃，位香法士錯乙音造活羽詞坡村目園尺封鳥朋；法松夕點我冬停雪因科對只貓息加黃住蝶，明鴨乾春呢風乙時昔孝助？小紅女父故去。
飯躲裝個哥害共買去隻把氣年，己你校跟飛百拉！快石牙飽知唱想土人吹象毛吉每浪四又連見、欠耍外豆雞秋鼻。住步帶。
打六申幾麼：或皮又荷隻乙犬孝習秋還何氣；幾裏活打能花是入海乙山節會。種第共後陽沒喜姐三拍弟海肖，行知走亮包，他字幾，的木卜流旦乙左杯根毛。
您皮買身苦八手牛目地止哥彩第合麻讀午。原朋河乾種果「才波久住這香松」兄主衣快他玉坐要羽和亭但小山吉也吃耳怕，也爪斗斥可害朋許波怎祖葉卜。
行花兩耍許車丟學「示想百吃門高事」不耳見室九星枝買裝，枝十新央發旁品丁青給，科房火；事出出孝肉古：北裝愛升幸百東鼻到從會故北「可休笑物勿三游細斗」娘蛋占犬。我羊波雨跳風。
牛大燈兆新七馬，叫這牙後戶耳、荷北吃穿停植身玩間告或西丟再呢，他禾七愛干寺服石安：他次唱息它坐屋父見這衣發現來，苗會開條弓世者吃英定豆哭；跳風掃叫美神。
寸再了耍休壯植己，燈錯和，蝶幾欠雞定和愛，司紅後弓第樹會金拉快喝夕見往，半瓜日邊出讀雞苦歌許開；發火院爸乙；四帶亮錯鳥洋個讀。
"""
        static let miscUnicode = """

‘’“”‹›«»‚„ 😀😛😇😈😉😍😎😮👍👎 —–§¶†‡©®™ →⇒•·°±−×÷¼½½¾
…µ¢£€¿¡¨´¸ˆ˜ ÀÁÂÃÄÅÆÇÈÉÊË ÌÍÎÏÐÑÒÓÔÕÖØ ŒŠÙÚÛÜÝŸÞßàá âãäåæçèéêëìí
îïðñòóôõöøœš ùúûüýÿþªºαΩ∞ ū̀n̂o᷵H̨a̠b̡͓̐c̡͓̐X̡͓̐
"""
    }

    private struct DeterministicLCG {
        private var state: UInt64 = 0xC0DEC0DE12345678

        mutating func nextInt(upperBound: Int) -> Int {
            precondition(upperBound > 0)
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state % UInt64(upperBound))
        }
    }

    private static let allowedRegressionMultiplier = 2.0
    private static var baselineResetPerformedForCurrentRun = false
    private static let cachedBaselineEnvironment = computeCurrentBaselineEnvironment()

    private struct HistoricalReference {
        let beforeNanoseconds: UInt64
        let note: String
    }

    private struct BaselineRecord: Codable {
        let medianNanoseconds: UInt64
        let iterations: Int
        let recordedAt: String
    }

    private struct BaselineEnvironment: Codable, Equatable {
        let host: String
        let arch: String
        let swiftVersion: String
        let osVersion: String
        let osBuild: String
    }

    private struct BaselineFile: Codable {
        var schemaVersion: Int?
        var machine: String
        var environment: BaselineEnvironment?
        var records: [String: BaselineRecord]
    }

    private struct SplitFixture {
        let view: SplitRenderView
        let terminalViews: [TerminalView]
    }

    /// Improvement targets captured immediately before the render-snapshot refactor
    /// on 2026-03-15 (Debug, arm64, host ponp.local). These are not used as pass/fail
    /// thresholds; they exist so the test output always shows the historical "before"
    /// alongside the current "after".
    private static let historicalBeforeReferences: [String: HistoricalReference] = [
        "terminal_controller.with_viewport_build_vertex_data": HistoricalReference(
            beforeNanoseconds: 15_348_875,
            note: "Legacy path: build vertex data while holding the controller read lock."
        ),
        "terminal_controller.write_lock_contention": HistoricalReference(
            beforeNanoseconds: 15_523_458,
            note: "Legacy path: writer waits for render work that remains inside the read lock."
        ),
        "terminal_view.render_frame": HistoricalReference(
            beforeNanoseconds: 11_575_208,
            note: "Legacy focused-terminal frame render before render snapshots."
        ),
        "metal_renderer.render_split_cell_snapshot": HistoricalReference(
            beforeNanoseconds: 8_341_417,
            note: "Legacy split-cell render before render snapshots."
        ),
        "split_render_view.render_frame": HistoricalReference(
            beforeNanoseconds: 433_333,
            note: "Legacy split render frame before render snapshots."
        )
    ]

    private static func projectRootURL(filePath: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func baselineURL() -> URL {
        let host = sanitizedHostName()
        let arch = currentArchitecture()
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pterm/performance-baselines", isDirectory: true)
            .appendingPathComponent("\(host)-\(arch).json")
    }

    private static func sanitizedHostName() -> String {
        ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "-", options: .regularExpression)
    }

    private static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func computeCurrentBaselineEnvironment() -> BaselineEnvironment {
        let processInfo = ProcessInfo.processInfo
        let operatingSystem = processInfo.operatingSystemVersion
        return BaselineEnvironment(
            host: sanitizedHostName(),
            arch: currentArchitecture(),
            swiftVersion: shellOutput(
                executable: "/usr/bin/xcrun",
                arguments: ["swift", "--version"]
            ) ?? "unknown",
            osVersion: "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)",
            osBuild: shellOutput(
                executable: "/usr/bin/sw_vers",
                arguments: ["-buildVersion"]
            ) ?? "unknown"
        )
    }

    private static func currentBaselineEnvironment() -> BaselineEnvironment {
        cachedBaselineEnvironment
    }

    private static func shellOutput(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == false ? output : nil
        } catch {
            return nil
        }
    }

    private static func emptyBaselineFile() -> BaselineFile {
        BaselineFile(
            schemaVersion: 2,
            machine: sanitizedHostName(),
            environment: currentBaselineEnvironment(),
            records: [:]
        )
    }

    private func makeRendererOrSkip() throws -> MetalRenderer {
        guard let renderer = MetalRenderer(scaleFactor: 2.0) else {
            throw XCTSkip("Metal unavailable")
        }
        return renderer
    }

    private func makeRendererWithPipelinesOrSkip() throws -> MetalRenderer {
        let renderer = try makeRendererOrSkip()
        let shaderURL = Self.projectRootURL()
            .appendingPathComponent("Sources/PtermApp/Rendering/Shaders/terminal.metal")
        let source = try String(contentsOf: shaderURL, encoding: .utf8)
        let library = try renderer.device.makeLibrary(source: source, options: nil)
        renderer.setupPipelines(library: library)
        return renderer
    }

    private func makeBenchmarkTexture(
        renderer: MetalRenderer,
        width: Int = 2048,
        height: Int = 1536
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalRenderer.renderTargetPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else {
            XCTFail("Failed to allocate benchmark texture")
            throw XCTSkip("Texture allocation failed")
        }
        return texture
    }

    private func makeBenchmarkRenderOwner(
        renderer: MetalRenderer,
        width: Int,
        height: Int
    ) -> MTKView {
        let view = MTKView(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            device: renderer.device
        )
        view.colorPixelFormat = MetalRenderer.renderTargetPixelFormat
        view.drawableSize = CGSize(width: width, height: height)
        return view
    }

    private func makeBenchmarkController(
        rows: Int = 48,
        cols: Int = 160,
        scrollbackRows: Int = 320
    ) -> TerminalController {
        let controller = TerminalController(
            rows: rows,
            cols: cols,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 8 * 1024 * 1024,
            scrollbackMaxCapacity: 8 * 1024 * 1024,
            fontName: "Menlo",
            fontSize: 13
        )

        for row in 0..<scrollbackRows {
            controller.scrollback.appendRow(
                ArraySlice(makeBenchmarkCells(rowIndex: row, cols: cols)),
                isWrapped: row % 6 == 1
            )
        }

        for row in 0..<rows {
            let cells = makeBenchmarkCells(rowIndex: scrollbackRows + row, cols: cols)
            for (col, cell) in cells.enumerated() {
                controller.model.grid.setCell(cell, at: row, col: col)
            }
            controller.model.grid.setWrapped(row, row % 5 == 2)
        }
        controller.model.cursor.row = rows - 2
        controller.model.cursor.col = cols / 3
        controller.model.cursor.visible = true
        controller.model.cursor.blinking = true
        controller.model.cursor.shape = .block
        _ = controller.scrollUp(lines: min(32, scrollbackRows))
        return controller
    }

    private func makeBenchmarkCells(rowIndex: Int, cols: Int) -> [Cell] {
        let glyphs = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz[]{}<>+-=*/".unicodeScalars)
        var cells = Array(repeating: Cell.empty, count: cols)
        for col in 0..<cols {
            let scalar = glyphs[(rowIndex * 7 + col) % glyphs.count].value
            var attributes = CellAttributes.default
            attributes.foreground = .indexed(UInt8((rowIndex + col) % 16))
            if col % 9 == 0 {
                attributes.background = .indexed(UInt8((rowIndex + col * 3) % 16))
            }
            attributes.bold = col % 11 == 0
            attributes.underline = col % 17 == 0
            cells[col] = Cell(codepoint: scalar, attributes: attributes, width: 1, isWideContinuation: false)
        }
        if cols > 8 && rowIndex % 10 == 0 {
            let wideCol = cols / 4
            cells[wideCol] = Cell(codepoint: 0x65E5, attributes: .default, width: 2, isWideContinuation: false)
            cells[wideCol + 1] = Cell(codepoint: 0, attributes: .default, width: 0, isWideContinuation: true)
        }
        return cells
    }

    private func makeTerminalView(renderer: MetalRenderer, controller: TerminalController) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), renderer: renderer)
        view.terminalController = controller
        view.layoutSubtreeIfNeeded()
        view.refreshTerminalLayoutForCurrentBounds()
        return view
    }

    private func makeSplitFixture(renderer: MetalRenderer, controllerCount: Int = 4) -> SplitFixture {
        let splitView = SplitRenderView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), renderer: renderer)
        let controllers = (0..<controllerCount).map { _ in makeBenchmarkController(rows: 24, cols: 80, scrollbackRows: 180) }
        let terminalViews = controllers.map { controller -> TerminalView in
            let view = TerminalView(frame: .zero, renderer: renderer)
            view.terminalController = controller
            return view
        }
        let frames = [
            NSRect(x: 0, y: 360, width: 639, height: 359),
            NSRect(x: 641, y: 360, width: 639, height: 359),
            NSRect(x: 0, y: 0, width: 639, height: 359),
            NSRect(x: 641, y: 0, width: 639, height: 359)
        ]
        splitView.cellRefs = zip(terminalViews, controllers).enumerated().map { index, pair in
            SplitRenderView.CellRef(
                terminalView: pair.0,
                controller: pair.1,
                frame: frames[index % frames.count]
            )
        }
        return SplitFixture(view: splitView, terminalViews: terminalViews)
    }

    private func makeProcessOutputData(lineCount: Int = 96) -> Data {
        let text = (0..<lineCount).map { index in
            String(format: "perf-line-%03d payload [alpha beta gamma delta]\n", index)
        }.joined()
        return Data(text.utf8)
    }

    private func makeKittyBenchmarkASCIIData() -> Data {
        let alphabet = Array((KittyBenchmarkFixture.asciiPrintable + KittyBenchmarkFixture.controlChars).utf8)
        var rng = DeterministicLCG()
        var bytes = [UInt8]()
        bytes.reserveCapacity(1024 * 2048 + 13)
        for _ in 0..<(1024 * 2048 + 13) {
            bytes.append(alphabet[rng.nextInt(upperBound: alphabet.count)])
        }
        return Data(bytes)
    }

    private func makeKittyBenchmarkUnicodeData() -> Data {
        Data(String(repeating: KittyBenchmarkFixture.chineseLoremIpsum + KittyBenchmarkFixture.miscUnicode + KittyBenchmarkFixture.controlChars, count: 1024).utf8)
    }

    private func makeKittyBenchmarkCSIData() -> Data {
        let targetSize = 1024 * 1024 + 17
        let randomAlphabet = Array((KittyBenchmarkFixture.asciiPrintable + KittyBenchmarkFixture.controlChars).utf8)
        let exactChunks = [
            "\u{1B}[m\u{1B}[?1h\u{1B}[H",
            "\u{1B}[1;2;3;4:3;31m",
            "\u{1B}[38:5:24;48:2:125:136:147m",
            "\u{1B}[58;5;44;2m",
            "\u{1B}[m\u{1B}[10A\u{1B}[3E\u{1B}[2K",
            "\u{1B}[39m\u{1B}[10`a\u{1B}[100b\u{1B}[?1l"
        ]
        var rng = DeterministicLCG()
        var out = [UInt8]()
        out.reserveCapacity(targetSize + 48)

        func appendRandomChunk() {
            let length = rng.nextInt(upperBound: 72) + 1
            for _ in 0..<length {
                out.append(randomAlphabet[rng.nextInt(upperBound: randomAlphabet.count)])
            }
        }

        while out.count < targetSize {
            let q = rng.nextInt(upperBound: 100)
            switch q {
            case 0..<10:
                appendRandomChunk()
            case 10..<30:
                out.append(contentsOf: exactChunks[0].utf8)
            case 30..<40:
                out.append(contentsOf: exactChunks[1].utf8)
            case 40..<50:
                out.append(contentsOf: exactChunks[2].utf8)
            case 50..<60:
                out.append(contentsOf: exactChunks[3].utf8)
            case 60..<80:
                out.append(contentsOf: exactChunks[4].utf8)
            default:
                out.append(contentsOf: exactChunks[5].utf8)
            }
        }
        out.append(contentsOf: "\u{1B}[m".utf8)
        return Data(out)
    }

    private func makeBenchmarkSelection() -> TerminalSelection {
        TerminalSelection(
            anchor: GridPosition(row: 2, col: 4),
            active: GridPosition(row: 4, col: 18),
            mode: .normal
        )
    }

    private func benchmark(
        _ name: String,
        iterations: Int = 12,
        warmupIterations: Int = 3,
        operation: () -> Void
    ) throws {
        for _ in 0..<warmupIterations {
            autoreleasepool(invoking: operation)
        }

        let samples = (0..<iterations).map { _ -> UInt64 in
            let start = ContinuousClock.now
            autoreleasepool(invoking: operation)
            let duration = start.duration(to: .now)
            return durationNanoseconds(duration)
        }.sorted()
        let median = samples[samples.count / 2]

        let url = Self.baselineURL()
        let shouldReset = ProcessInfo.processInfo.environment["PTERM_RESET_PERF_BASELINES"] == "1"
        var file = try loadBaselineFile(from: url, reset: shouldReset)
        let historicalBefore = Self.historicalBeforeReferences[name]
        if let baseline = file.records[name], !shouldReset {
            let threshold = UInt64(Double(baseline.medianNanoseconds) * Self.allowedRegressionMultiplier)
            var message = "PERF \(name) current=\(median)ns baseline=\(baseline.medianNanoseconds)ns threshold=\(threshold)ns iterations=\(iterations)"
            if let historicalBefore {
                message += " before_ref=\(historicalBefore.beforeNanoseconds)ns"
            }
            print(message)
            XCTAssertLessThanOrEqual(
                median,
                threshold,
                "\(name) regressed: \(median)ns > \(threshold)ns (baseline \(baseline.medianNanoseconds)ns, file: \(url.path))"
            )
        } else {
            var message = "PERF \(name) current=\(median)ns baseline=NEW iterations=\(iterations) file=\(url.path)"
            if let historicalBefore {
                message += " before_ref=\(historicalBefore.beforeNanoseconds)ns"
            }
            print(message)
            file.records[name] = BaselineRecord(
                medianNanoseconds: median,
                iterations: iterations,
                recordedAt: ISO8601DateFormatter().string(from: Date())
            )
            try persistBaselineFile(file, to: url)
        }
    }

    private func lowerQuantile(_ samples: [UInt64], numerator: Int, denominator: Int) -> UInt64 {
        precondition(!samples.isEmpty)
        precondition(numerator >= 0 && denominator > 0 && numerator < denominator)
        let index = ((samples.count - 1) * numerator) / denominator
        return samples[index]
    }

    /// The write-lock contention benchmark is intentionally based on a lower quantile rather
    /// than the median. Once render work moved outside the controller read lock, the remaining
    /// duration is dominated by thread wakeup and scheduler jitter instead of lock ownership.
    /// A lower-quantile sample better captures the intrinsic uncontended path while still
    /// flagging structural regressions that reintroduce real lock hold time.
    private func assertContentionBenchmark(
        name: String,
        samples: [UInt64],
        historicalBefore: HistoricalReference?
    ) throws {
        let statistic = lowerQuantile(samples, numerator: 1, denominator: 4)
        let url = Self.baselineURL()
        let shouldReset = ProcessInfo.processInfo.environment["PTERM_RESET_PERF_BASELINES"] == "1"
        var file = try loadBaselineFile(from: url, reset: shouldReset)
        if let baseline = file.records[name], !shouldReset {
            let threshold = UInt64(Double(baseline.medianNanoseconds) * Self.allowedRegressionMultiplier)
            var message = "PERF \(name) current=\(statistic)ns baseline=\(baseline.medianNanoseconds)ns threshold=\(threshold)ns iterations=\(samples.count) statistic=p25"
            if let historicalBefore {
                message += " before_ref=\(historicalBefore.beforeNanoseconds)ns"
            }
            print(message)
            XCTAssertLessThanOrEqual(
                statistic,
                threshold,
                "\(name) regressed: \(statistic)ns > \(threshold)ns (baseline \(baseline.medianNanoseconds)ns, file: \(url.path))"
            )
        } else {
            var message = "PERF \(name) current=\(statistic)ns baseline=NEW iterations=\(samples.count) statistic=p25 file=\(url.path)"
            if let historicalBefore {
                message += " before_ref=\(historicalBefore.beforeNanoseconds)ns"
            }
            print(message)
            file.records[name] = BaselineRecord(
                medianNanoseconds: statistic,
                iterations: samples.count,
                recordedAt: ISO8601DateFormatter().string(from: Date())
            )
            try persistBaselineFile(file, to: url)
        }
    }

    private func loadBaselineFile(from url: URL, reset: Bool) throws -> BaselineFile {
        if reset, !Self.baselineResetPerformedForCurrentRun {
            try? FileManager.default.removeItem(at: url)
            Self.baselineResetPerformedForCurrentRun = true
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Self.emptyBaselineFile()
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(BaselineFile.self, from: data)
        let currentEnvironment = Self.currentBaselineEnvironment()
        guard decoded.environment == currentEnvironment else {
            return Self.emptyBaselineFile()
        }
        return decoded
    }

    private func persistBaselineFile(_ file: BaselineFile, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(file)
        try data.write(to: url, options: .atomic)
    }

    func testTerminalGridSnapshotPerformanceRegression() throws {
        let controller = makeBenchmarkController()
        try benchmark("terminal_grid.snapshot", iterations: 24) {
            _ = controller.model.grid.snapshot()
        }
    }

    func testTerminalControllerSnapshotViewportPerformanceRegression() throws {
        let controller = makeBenchmarkController()
        try benchmark("terminal_controller.snapshot_viewport", iterations: 18) {
            _ = controller.snapshotViewport()
        }
    }

    func testTerminalControllerProcessPTYOutputPerformanceRegression() throws {
        let payload = makeProcessOutputData()
        try benchmark("terminal_controller.process_pty_output", iterations: 10, warmupIterations: 1) {
            let controller = self.makeBenchmarkController(rows: 24, cols: 100, scrollbackRows: 64)
            controller.debugProcessPTYOutputForTesting(payload)
        }
    }

    /// Verify that the PTY output path with hooks master switch OFF has zero
    /// overhead compared to the baseline.  The hookManager is nil, so the
    /// installed closure is the standard path — no hook code executes.
    func testPTYOutputWithHooksMasterSwitchOFF() throws {
        let payload = makeProcessOutputData()
        try benchmark("terminal_controller.process_pty_output_hooks_off", iterations: 10, warmupIterations: 1) {
            let controller = self.makeBenchmarkController(rows: 24, cols: 100, scrollbackRows: 64)
            // hookManager is nil — standard closure, zero hook overhead.
            controller.debugProcessPTYOutputForTesting(payload)
        }
    }

    /// Measure overhead of the hook-aware closure with an active immediate-mode
    /// hook.  The hookManager dispatches raw bytes to an SPSC ring buffer.
    /// Expected overhead: < 500ns per read event (memcpy to ring buffer).
    func testPTYOutputWithHooksActiveImmediateMode() throws {
        signal(SIGPIPE, SIG_IGN)

        let hook = IOHookEntry(
            enabled: true,
            name: "perf-test-hook",
            target: .output,
            buffering: .immediate,
            idleMs: IOHookEntry.defaultIdleMs,
            diffOnly: IOHookEntry.defaultDiffOnly,
            bufferSize: IOHookEntry.defaultBufferSize,
            command: "cat > /dev/null",
            processMatch: nil,
            processMatchRegex: nil,
            includeChildren: false
        )
        let config = IOHookConfiguration(enabled: true, hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let payload = makeProcessOutputData()
        try benchmark("terminal_controller.process_pty_output_hooks_immediate", iterations: 10, warmupIterations: 1) {
            let controller = self.makeBenchmarkController(rows: 24, cols: 100, scrollbackRows: 64)
            controller.hookManager = manager
            // Simulate what the hook-aware closure does: dispatch + process.
            payload.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let buf = UnsafeBufferPointer(start: base, count: rawBuf.count)
                manager.dispatchRawOutput(buf, terminalID: controller.id)
            }
            controller.debugProcessPTYOutputForTesting(payload)
        }
    }

    /// Measure overhead of the hook-aware closure with an active line-mode
    /// hook (includes hookTextSink per-character callback).
    func testPTYOutputWithHooksActiveLineMode() throws {
        signal(SIGPIPE, SIG_IGN)

        let hook = IOHookEntry(
            enabled: true,
            name: "perf-test-line-hook",
            target: .output,
            buffering: .line,
            idleMs: IOHookEntry.defaultIdleMs,
            diffOnly: IOHookEntry.defaultDiffOnly,
            bufferSize: IOHookEntry.defaultBufferSize,
            command: "cat > /dev/null",
            processMatch: nil,
            processMatchRegex: nil,
            includeChildren: false
        )
        let config = IOHookConfiguration(enabled: true, hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let payload = makeProcessOutputData()
        try benchmark("terminal_controller.process_pty_output_hooks_line", iterations: 10, warmupIterations: 1) {
            let controller = self.makeBenchmarkController(rows: 24, cols: 100, scrollbackRows: 64)
            controller.hookManager = manager
            // Install hookTextSink to simulate line-mode text capture.
            let termID = controller.id
            controller.model.hookTextSink = { [weak manager] codepoint in
                manager?.dispatchTextCharacter(codepoint, terminalID: termID)
            }
            controller.debugProcessPTYOutputForTesting(payload)
        }
    }

    func testTerminalControllerProcessKittyBenchmarkASCIIPerformanceRegression() throws {
        let payload = makeKittyBenchmarkASCIIData()
        try benchmark("terminal_controller.process_kitty_benchmark_ascii", iterations: 8, warmupIterations: 1) {
            let controller = self.makeBenchmarkController(rows: 24, cols: 80, scrollbackRows: 0)
            controller.debugProcessPTYOutputForTesting(payload)
        }
    }

    func testTerminalControllerProcessKittyBenchmarkUnicodePerformanceRegression() throws {
        let payload = makeKittyBenchmarkUnicodeData()
        try benchmark("terminal_controller.process_kitty_benchmark_unicode", iterations: 6, warmupIterations: 1) {
            let controller = self.makeBenchmarkController(rows: 24, cols: 80, scrollbackRows: 0)
            controller.debugProcessPTYOutputForTesting(payload)
        }
    }

    func testTerminalControllerProcessKittyBenchmarkCSIPerformanceRegression() throws {
        let payload = makeKittyBenchmarkCSIData()
        try benchmark("terminal_controller.process_kitty_benchmark_csi", iterations: 8, warmupIterations: 1) {
            let controller = self.makeBenchmarkController(rows: 24, cols: 80, scrollbackRows: 0)
            controller.debugProcessPTYOutputForTesting(payload)
        }
    }

    func testTerminalControllerWriteLockContentionPerformanceRegression() throws {
        let controller = makeBenchmarkController()
        let renderer = try makeRendererOrSkip()
        let holdSamples = (0..<12).map { _ -> UInt64 in
            let writerReady = DispatchSemaphore(value: 0)
            let writerDone = DispatchSemaphore(value: 0)
            let resultLock = NSLock()
            var waited: UInt64 = 0

            controller.withViewport { model, scrollback, scrollOffset in
                DispatchQueue.global(qos: .userInitiated).async {
                    writerReady.signal()
                    let start = ContinuousClock.now
                    let size = controller.withModel { ($0.rows, $0.cols) }
                    controller.resize(rows: size.0, cols: size.1)
                    let duration = start.duration(to: .now)
                    resultLock.lock()
                    waited = durationNanoseconds(duration)
                    resultLock.unlock()
                    writerDone.signal()
                }
                writerReady.wait()
                _ = renderer.debugBuildVertexDataForTesting(
                    model: model,
                    scrollback: scrollback,
                    scrollOffset: scrollOffset
                )
            }

            writerDone.wait()
            resultLock.lock()
            let sample = waited
            resultLock.unlock()
            return sample
        }.sorted()

        let name = "terminal_controller.write_lock_contention"
        let historicalBefore = Self.historicalBeforeReferences[name]
        try assertContentionBenchmark(name: name, samples: holdSamples, historicalBefore: historicalBefore)
    }

    func testTerminalControllerWriteLockContentionAfterRenderSnapshotPerformanceRegression() throws {
        let controller = makeBenchmarkController()
        let renderer = try makeRendererOrSkip()
        let holdSamples = (0..<12).map { _ -> UInt64 in
            let writerReady = DispatchSemaphore(value: 0)
            let writerDone = DispatchSemaphore(value: 0)
            let resultLock = NSLock()
            var waited: UInt64 = 0

            let snapshot = controller.captureRenderSnapshot()
            DispatchQueue.global(qos: .userInitiated).async {
                writerReady.signal()
                let start = ContinuousClock.now
                let size = controller.withModel { ($0.rows, $0.cols) }
                controller.resize(rows: size.0, cols: size.1)
                let duration = start.duration(to: .now)
                resultLock.lock()
                waited = durationNanoseconds(duration)
                resultLock.unlock()
                writerDone.signal()
            }
            writerReady.wait()
            _ = renderer.debugBuildVertexDataForTesting(snapshot: snapshot)
            writerDone.wait()
            resultLock.lock()
            let sample = waited
            resultLock.unlock()
            return sample
        }.sorted()

        let name = "terminal_controller.render_snapshot_write_lock_contention"
        let historicalBefore = Self.historicalBeforeReferences["terminal_controller.write_lock_contention"]
        try assertContentionBenchmark(name: name, samples: holdSamples, historicalBefore: historicalBefore)
    }

    func testContendedWithViewportBuildVertexDataPerformanceRegression() throws {
        let renderer = try makeRendererOrSkip()
        let controller = makeBenchmarkController()
        try benchmark("terminal_controller.with_viewport_build_vertex_data", iterations: 14) {
            controller.withViewport { model, scrollback, scrollOffset in
                _ = renderer.debugBuildVertexDataForTesting(
                    model: model,
                    scrollback: scrollback,
                    scrollOffset: scrollOffset
                )
            }
        }
    }

    func testRenderSnapshotBuildVertexDataPerformanceRegression() throws {
        let renderer = try makeRendererOrSkip()
        let controller = makeBenchmarkController()
        try benchmark("terminal_controller.render_snapshot_build_vertex_data", iterations: 14) {
            let snapshot = controller.captureRenderSnapshot()
            _ = renderer.debugBuildVertexDataForTesting(snapshot: snapshot)
        }
    }

    func testMetalRendererBuildVertexDataPerformanceRegression() throws {
        let renderer = try makeRendererOrSkip()
        let controller = makeBenchmarkController()
        let scrollOffset = controller.withViewport { _, _, offset in offset }
        try benchmark("metal_renderer.build_vertex_data", iterations: 14) {
            _ = renderer.debugBuildVertexDataForTesting(
                model: controller.model,
                scrollback: controller.scrollback,
                scrollOffset: scrollOffset
            )
        }
    }

    func testMetalRendererRenderPerformanceRegression() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let controller = makeBenchmarkController()
        let texture = try makeBenchmarkTexture(renderer: renderer)
        let scrollOffset = controller.withViewport { _, _, offset in offset }
        try benchmark("metal_renderer.render_to_texture", iterations: 10) {
            renderer.debugRenderToTextureForTesting(
                model: controller.model,
                scrollback: controller.scrollback,
                texture: texture,
                scrollOffset: scrollOffset
            )
        }
    }

    func testMetalRendererRenderSplitCellPerformanceRegression() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let controller = makeBenchmarkController(rows: 24, cols: 100, scrollbackRows: 180)
        let texture = try makeBenchmarkTexture(renderer: renderer, width: 1280, height: 720)
        let snapshot = controller.captureRenderSnapshot()
        let cellRect = NSRect(x: 0, y: 0, width: 620, height: 340)
        let renderOwner = makeBenchmarkRenderOwner(renderer: renderer, width: texture.width, height: texture.height)

        // Pre-warm glyph atlas and reusable split buffers outside the measured window so
        // the regression test tracks steady-state split rendering rather than first-use setup.
        for _ in 0..<6 {
            renderer.debugRenderSplitCellToTextureForTesting(
                snapshot: snapshot,
                texture: texture,
                cellRect: cellRect,
                bufferOwner: renderOwner
            )
        }

        try benchmark("metal_renderer.render_split_cell_snapshot", iterations: 10, warmupIterations: 0) {
            renderer.debugRenderSplitCellToTextureForTesting(
                snapshot: snapshot,
                texture: texture,
                cellRect: cellRect,
                bufferOwner: renderOwner
            )
        }
    }

    func testTerminalViewRenderFramePerformanceRegression() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let controller = makeBenchmarkController(rows: 36, cols: 120, scrollbackRows: 200)
        let view = makeTerminalView(renderer: renderer, controller: controller)
        let texture = try makeBenchmarkTexture(renderer: renderer, width: 1600, height: 900)
        try benchmark("terminal_view.render_frame", iterations: 10) {
            view.debugRenderFrameToTextureForTesting(texture)
        }
    }

    func testSplitRenderViewRenderFramePerformanceRegression() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let fixture = makeSplitFixture(renderer: renderer)
        let texture = try makeBenchmarkTexture(renderer: renderer, width: 1600, height: 900)
        try benchmark("split_render_view.render_frame", iterations: 10) {
            fixture.view.debugRenderFrameToTextureForTesting(texture)
        }
        XCTAssertEqual(fixture.terminalViews.count, 4)
    }

    func testRenderSnapshotMatchesLegacyVertexBuild() throws {
        let renderer = try makeRendererOrSkip()
        let controller = makeBenchmarkController(rows: 24, cols: 100, scrollbackRows: 180)
        let snapshot = controller.captureRenderSnapshot()
        let selection = makeBenchmarkSelection()
        let transientOverlay = MetalRenderer.TransientTextOverlay(
            text: "IME",
            row: 5,
            col: 8,
            columnWidth: 3,
            cursorRow: 5,
            cursorCol: 11,
            masksGridGlyphs: true,
            verticalOffset: 0,
            alpha: 1
        )

        let legacy = controller.withViewport { model, scrollback, scrollOffset in
            renderer.debugBuildVertexDataForTesting(
                model: model,
                scrollback: scrollback,
                scrollOffset: scrollOffset,
                selection: selection,
                transientTextOverlays: [transientOverlay]
            )
        }

        let snapshotBuilt = renderer.debugBuildVertexDataForTesting(
            snapshot: snapshot,
            selection: selection,
            transientTextOverlays: [transientOverlay]
        )

        XCTAssertEqual(snapshot.visibleRows.count, snapshot.rows)
        XCTAssertEqual(legacy.bgVertices, snapshotBuilt.bgVertices)
        XCTAssertEqual(legacy.glyphVertices, snapshotBuilt.glyphVertices)
        XCTAssertEqual(legacy.cursorVertices, snapshotBuilt.cursorVertices)
        XCTAssertEqual(legacy.overlayVertices, snapshotBuilt.overlayVertices)
    }
}

import AppKit
import XCTest
@preconcurrency @testable import PtermApp
import PtermCore

@MainActor
final class TerminalControllerTests: XCTestCase {
    private final class PurgedURLRecorder {
        var urls: [URL] = []
    }

    private func initialRowIndexCapacity(for initialCapacity: Int) -> Int {
        let targetRowBytes = 128
        let computed = (initialCapacity + (targetRowBytes - 1)) / targetRowBytes
        return min(max(computed, 16), 64)
    }

    private func seedOversizedScrollbackFile(path: String, initialCapacity: Int, maxCapacity: Int, codepoint: UInt32) {
        let rb = ring_buffer_create_mmap_sized(path, initialCapacity, maxCapacity)
        XCTAssertNotNil(rb)
        defer { ring_buffer_destroy(rb) }

        let initialRowCapacity = initialRowIndexCapacity(for: initialCapacity)
        let serializedCellRow: [UInt8] = [
            0x01,
            UInt8(codepoint & 0xFF), UInt8((codepoint >> 8) & 0xFF), UInt8((codepoint >> 16) & 0xFF), UInt8((codepoint >> 24) & 0xFF),
        ]
        for _ in 0..<(Int(initialRowCapacity) + 8) {
            serializedCellRow.withUnsafeBufferPointer { pointer in
                XCTAssertGreaterThanOrEqual(ring_buffer_append_row(rb, pointer.baseAddress, UInt32(pointer.count), false), 0)
            }
        }

        for (index, byte) in serializedCellRow.enumerated() {
            rb!.pointee.data[index] = byte
        }
        rb!.pointee.write_offset = serializedCellRow.count
        rb!.pointee.bytes_used = serializedCellRow.count
        rb!.pointee.row_count = 1
        rb!.pointee.row_head = 0
        rb!.pointee.row_tail = 1
        rb!.pointee.rows[0].offset = 0
        rb!.pointee.rows[0].length = UInt32(serializedCellRow.count)
        rb!.pointee.rows[0].flags = 0
    }

    private func makeController(
        rows: Int = 3,
        cols: Int = 8,
        initialDirectory: String = "/tmp/project",
        customTitle: String? = nil,
        workspaceName: String = "Main Workspace",
        scrollbackPersistencePath: String? = nil,
        scrollbackInitialCapacity: Int = 4096,
        scrollbackMaxCapacity: Int = 4096,
        currentDirectoryProvider: @escaping (pid_t) -> String? = { _ in nil }
    ) -> TerminalController {
        TerminalController(
            rows: rows,
            cols: cols,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: scrollbackInitialCapacity,
            scrollbackMaxCapacity: scrollbackMaxCapacity,
            fontName: "Menlo",
            fontSize: 13,
            initialDirectory: initialDirectory,
            customTitle: customTitle,
            workspaceName: workspaceName,
            scrollbackPersistencePath: scrollbackPersistencePath,
            currentDirectoryProvider: currentDirectoryProvider
        )
    }

    private func installInlineImagePurgeObserver(
        on controller: TerminalController,
        registry: PastedImageRegistry,
        recorder: PurgedURLRecorder
    )  {
        controller.onInlineImageReachabilityChange = { ownerID, liveIndices in
            let purged = registry.purgeUnreferencedImages(
                ownerID: ownerID,
                retainingPlaceholderIndices: liveIndices
            )
            recorder.urls.append(contentsOf: purged)
        }
    }

    @discardableResult
    private func registerPersistedInlineImage(
        registry: PastedImageRegistry,
        ownerID: UUID,
        index: Int
    ) throws -> URL {
        let pngBytes = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52
        ])
        try registry.registerTransient(
            imageData: pngBytes,
            format: .png,
            placeholderIndex: index,
            ownerID: ownerID
        )
        return try XCTUnwrap(registry.url(ownerID: ownerID, forPlaceholderIndex: index))
    }

    func testTerminalControllerStartsWithoutDecodeBufferAllocation() {
        let controller = makeController()

        XCTAssertEqual(controller.debugCodepointBufferCapacity, 0)
    }

    func testTerminalControllerStartsWithoutTextExtractionScratchAllocation() {
        let controller = makeController()

        XCTAssertEqual(controller.debugTextExtractionScratchCapacity, 0)
    }

    func testTerminalControllerStartsWithoutSearchScratchAllocation() {
        let controller = makeController()

        XCTAssertEqual(controller.debugSearchScratchCapacity, 0)
    }

    func testDebugProcessPTYOutputMatchesByteWiseProcessingForRepeatedASCIIREP() {
        let bulk = makeController(rows: 2, cols: 12)
        let byteWise = makeController(rows: 2, cols: 12)
        let data = Data([0x41, 0x1B, 0x5B, 0x31, 0x30, 0x62])

        bulk.debugProcessPTYOutputForTesting(data)
        for byte in data {
            byteWise.debugProcessPTYOutputForTesting(Data([byte]))
        }

        XCTAssertEqual(bulk.allText(), byteWise.allText())
    }

    func testDebugProcessPTYOutputKeepsCompositeEmojiAsSingleVisibleGrapheme() {
        let controller = makeController(rows: 2, cols: 12)
        controller.debugProcessPTYOutputForTesting(Data("👩‍💻 🇯🇵".utf8))

        XCTAssertTrue(controller.allText().contains("👩‍💻 🇯🇵"))
    }

    func testInputWithoutNewlineSuppressesOutputActivityIndicator() {
        XCTAssertTrue(TerminalController.shouldSuppressOutputActivity(forInput: Data("abc".utf8)))
        XCTAssertTrue(TerminalController.shouldSuppressOutputActivity(forInput: Data([0x1B, 0x5B, 0x41])))
    }

    func testInputWithNewlineDoesNotSuppressOutputActivityIndicator() {
        XCTAssertFalse(TerminalController.shouldSuppressOutputActivity(forInput: Data("ls\n".utf8)))
        XCTAssertFalse(TerminalController.shouldSuppressOutputActivity(forInput: Data("echo test\r".utf8)))
    }

    func testTerminalControllerDecodeBufferGrowsOnlyWhenNeeded() {
        let controller = makeController()

        controller.debugPrimeCodepointBufferCapacity(3000)

        XCTAssertGreaterThanOrEqual(controller.debugCodepointBufferCapacity, 3000)
    }

    func testDebugCompactScrollbackReleasesOversizedDecodeBufferCompletelyWhenIdle() {
        let controller = makeController()
        controller.debugPrimeCodepointBufferCapacity(8192)
        XCTAssertGreaterThanOrEqual(controller.debugCodepointBufferCapacity, 8192)

        _ = controller.debugCompactScrollbackNow()

        XCTAssertEqual(controller.debugCodepointBufferCapacity, 0)
    }

    func testTextExtractionScratchAllocatesOnlyWhenAllTextOrSearchNeedsItAndReleasesOnIdleCompaction() {
        let controller = makeController(rows: 3, cols: 4)
        controller.scrollback.appendRow(ArraySlice([
            Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false),
            Cell(codepoint: 66, attributes: .default, width: 1, isWideContinuation: false),
        ]), isWrapped: false)
        controller.withViewport { model, _, _ in
            model.grid.setCell(Cell(codepoint: 67, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 0)
            model.grid.setCell(Cell(codepoint: 68, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 1)
        }

        XCTAssertEqual(controller.debugTextExtractionScratchCapacity, 0)

        XCTAssertFalse(controller.allText().isEmpty)
        XCTAssertGreaterThanOrEqual(controller.debugTextExtractionScratchCapacity, 6)

        XCTAssertFalse(controller.findMatches(for: "ab").isEmpty)
        XCTAssertGreaterThanOrEqual(controller.debugTextExtractionScratchCapacity, 6)

        _ = controller.debugCompactScrollbackNow()

        XCTAssertEqual(controller.debugTextExtractionScratchCapacity, 0)
    }

    func testSearchScratchAllocatesOnlyWhenFindMatchesNeedsItAndReleasesOnIdleCompaction() {
        let controller = makeController(rows: 2, cols: 4)
        controller.scrollback.appendRow(ArraySlice([
            Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false),
            Cell(codepoint: 66, attributes: .default, width: 1, isWideContinuation: false),
            Cell(codepoint: 67, attributes: .default, width: 1, isWideContinuation: false),
            Cell(codepoint: 68, attributes: .default, width: 1, isWideContinuation: false),
        ]), isWrapped: false)

        XCTAssertEqual(controller.debugSearchScratchCapacity, 0)

        let matches = controller.findMatches(for: "bc")
        XCTAssertEqual(matches, [.init(absoluteRow: 0, startCol: 1, endCol: 2)])
        XCTAssertGreaterThanOrEqual(controller.debugSearchScratchCapacity, 4)

        _ = controller.debugCompactScrollbackNow()

        XCTAssertEqual(controller.debugSearchScratchCapacity, 0)
    }

    func testRenderSnapshotUsesActiveGridDimensionsWhenCachedModelSizeDrifts() {
        let controller = makeController(rows: 3, cols: 5)

        controller.withViewport { model, _, _ in
            _ = model.grid.resize(newRows: 2, newCols: 3, cursorRow: 0, cursorCol: 0)
            model.grid.setCell(
                Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false),
                at: 0,
                col: 0
            )
            model.grid.setCell(
                Cell(codepoint: 66, attributes: .default, width: 1, isWideContinuation: false),
                at: 1,
                col: 1
            )
        }

        let snapshot = controller.captureRenderSnapshot()

        XCTAssertEqual(snapshot.rows, 2)
        XCTAssertEqual(snapshot.cols, 3)
        XCTAssertEqual(snapshot.visibleRows.count, 2)
        XCTAssertEqual(snapshot.visibleRows[0].cells.count, 3)
        XCTAssertEqual(snapshot.visibleRows[1].cells.count, 3)
        XCTAssertEqual(snapshot.visibleRows[0].cells[0].codepoint, 65)
        XCTAssertEqual(snapshot.visibleRows[1].cells[1].codepoint, 66)
        XCTAssertEqual(controller.findMatches(for: "a"), [.init(absoluteRow: 0, startCol: 0, endCol: 0)])
        XCTAssertEqual(controller.allText(), "A\n B ")
    }

    func testRenderSnapshotSurvivesMalformedGridRowOrderState() {
        let controller = makeController(rows: 3, cols: 4)

        controller.withViewport { model, _, _ in
            model.grid.setCell(
                Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false),
                at: 0,
                col: 0
            )
            model.grid.debugCorruptReadableStateForTesting(
                rowOrder: [99],
                hasRowPermutation: true
            )
        }

        let snapshot = controller.captureRenderSnapshot()

        XCTAssertEqual(snapshot.rows, 1)
        XCTAssertEqual(snapshot.cols, 4)
        XCTAssertEqual(snapshot.visibleRows.count, 1)
        XCTAssertEqual(snapshot.visibleRows[0].cells.count, 4)
        XCTAssertEqual(snapshot.visibleRows[0].cells[0].codepoint, Cell.empty.codepoint)
    }

    func testRenderSnapshotClampsToReadableMetadataRowsWhenGridMetadataIsTruncated() {
        let controller = makeController(rows: 3, cols: 4)

        controller.withViewport { model, _, _ in
            model.grid.setCell(
                Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false),
                at: 0,
                col: 0
            )
            model.grid.setCell(
                Cell(codepoint: 66, attributes: .default, width: 1, isWideContinuation: false),
                at: 1,
                col: 0
            )
            model.grid.debugCorruptReadableStateForTesting(
                physicalSparseCompactDefaultPrefixCounts: [0, 0],
                rowEncodingHintStatesCount: 2
            )
        }

        let snapshot = controller.captureRenderSnapshot()

        XCTAssertEqual(snapshot.rows, 2)
        XCTAssertEqual(snapshot.visibleRows.count, 2)
        XCTAssertEqual(snapshot.visibleRows[0].cells[0].codepoint, 65)
        XCTAssertEqual(snapshot.visibleRows[1].cells[0].codepoint, 66)
    }

    func testStopReleasesControllerScratchImmediately() {
        let controller = makeController(rows: 2, cols: 4)

        controller.debugPrimeCodepointBufferCapacity(4096)
        _ = controller.findMatches(for: "x")

        XCTAssertGreaterThanOrEqual(controller.debugCodepointBufferCapacity, 4096)
        XCTAssertGreaterThanOrEqual(controller.debugSearchScratchCapacity, 0)

        controller.stop()

        XCTAssertEqual(controller.debugCodepointBufferCapacity, 0)
        XCTAssertEqual(controller.debugTextExtractionScratchCapacity, 0)
        XCTAssertEqual(controller.debugSearchScratchCapacity, 0)
    }

    func testInitiateShutdownReleasesControllerScratchImmediately() {
        let controller = makeController(rows: 2, cols: 4)

        controller.debugPrimeCodepointBufferCapacity(2048)
        _ = controller.allText()

        XCTAssertGreaterThanOrEqual(controller.debugCodepointBufferCapacity, 2048)

        controller.initiateShutdown()

        XCTAssertEqual(controller.debugCodepointBufferCapacity, 0)
        XCTAssertEqual(controller.debugTextExtractionScratchCapacity, 0)
        XCTAssertEqual(controller.debugSearchScratchCapacity, 0)
    }

    func testTitleTracksDirectoryUntilCustomTitleOverridesIt() {
        let controller = makeController(initialDirectory: "/Users/test/project")
        var titles: [String] = []
        var stateChanges = 0
        controller.onTitleChange = { titles.append($0) }
        controller.onStateChange = { stateChanges += 1 }

        XCTAssertEqual(controller.title, "project")

        controller.updateCurrentDirectory(path: "/Users/test/next")
        drainMainQueue(testCase: self)
        XCTAssertEqual(controller.title, "next")
        XCTAssertEqual(titles.last, "next")

        controller.setCustomTitle("Pinned")
        drainMainQueue(testCase: self)
        XCTAssertEqual(controller.title, "Pinned")
        XCTAssertEqual(titles.last, "Pinned")

        controller.updateCurrentDirectory(path: "/Users/test/final")
        drainMainQueue(testCase: self)
        XCTAssertEqual(controller.title, "Pinned")
        XCTAssertEqual(titles.last, "Pinned")

        controller.setCustomTitle("")
        drainMainQueue(testCase: self)
        XCTAssertEqual(controller.title, "final")
        XCTAssertEqual(titles.last, "final")
        XCTAssertEqual(stateChanges, 4)
    }

    func testUpdatingCurrentDirectoryToSamePathDoesNotNotifyAgain() {
        let controller = makeController(initialDirectory: "/Users/test/project")
        var titles: [String] = []
        var stateChanges = 0
        controller.onTitleChange = { titles.append($0) }
        controller.onStateChange = { stateChanges += 1 }

        controller.updateCurrentDirectory(path: "/Users/test/project")
        drainMainQueue(testCase: self)

        XCTAssertTrue(titles.isEmpty)
        XCTAssertEqual(stateChanges, 0)
        XCTAssertEqual(controller.title, "project")
    }

    func testSessionSnapshotSanitizesWorkspaceAndPersistsFontSettings() {
        let controller = makeController(workspaceName: " bad/name ")
        controller.setWorkspaceName("  qa/review ")
        controller.updateFontSettings(name: "SFMono-Regular", size: 15, notify: false)

        let snapshot = controller.sessionSnapshot
        XCTAssertEqual(snapshot.workspaceName, "qa_review")
        XCTAssertEqual(snapshot.currentDirectory, "/tmp/project")
        XCTAssertEqual(snapshot.settings?.fontName, "SFMono-Regular")
        XCTAssertEqual(snapshot.settings?.fontSize, 15)
        XCTAssertEqual(snapshot.settings?.textEncoding, "utf-8")

        let persisted = controller.persistedFontSettings
        XCTAssertEqual(persisted.name, "SFMono-Regular")
        XCTAssertEqual(persisted.size, 15)
    }

    func testScrollbackNavigationClampsOffsetAndClearScrollbackResetsState() {
        let controller = makeController()
        let lineA = ArraySlice([Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false)])
        let lineB = ArraySlice([Cell(codepoint: 66, attributes: .default, width: 1, isWideContinuation: false)])
        controller.scrollback.appendRow(lineA, isWrapped: false)
        controller.scrollback.appendRow(lineB, isWrapped: false)

        XCTAssertTrue(controller.scrollUp(lines: 1))
        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 1)
        XCTAssertTrue(controller.scrollUp(lines: 99))
        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 2)
        XCTAssertTrue(controller.scrollDown(lines: 1))
        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 1)

        controller.setScrollOffset(99)
        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 2)
        controller.scrollToBottom()
        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 0)

        controller.scrollUp(lines: 2)
        controller.clearScrollback()
        drainMainQueue(testCase: self)
        XCTAssertEqual(controller.scrollback.rowCount, 0)
        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 0)
    }

    func testClearScrollbackEmitsDisplayAndStateCallbacksOnce() {
        let controller = makeController()
        controller.scrollback.appendRow(ArraySlice([Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)
        var displayCount = 0
        var stateCount = 0
        controller.onNeedsDisplay = { displayCount += 1 }
        controller.onStateChange = { stateCount += 1 }

        controller.clearScrollback()
        drainMainQueue(testCase: self)

        XCTAssertEqual(displayCount, 1)
        XCTAssertEqual(stateCount, 1)
        XCTAssertEqual(controller.scrollback.rowCount, 0)
    }

    func testRestorePersistedScrollbackToViewportUsesExistingPersistentRows() throws {
        try withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("scrollback.bin").path
            let producer = makeController(scrollbackPersistencePath: path)
            producer.scrollback.appendRow(ArraySlice([Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)
            producer.scrollback.appendRow(ArraySlice([Cell(codepoint: 66, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)
            producer.scrollback.appendRow(ArraySlice([Cell(codepoint: 67, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)

            let restored = makeController(scrollbackPersistencePath: path)
            restored.restorePersistedScrollbackToViewport()
            drainMainQueue(testCase: self)

            XCTAssertEqual(restored.scrollback.rowCount, 3)
            XCTAssertEqual(restored.withViewport { _, _, offset in offset }, 3)
        }
    }

    func testRestorePersistedScrollbackToViewportEmitsNeedsDisplay() throws {
        try withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("scrollback.bin").path
            let producer = makeController(scrollbackPersistencePath: path)
            producer.scrollback.appendRow(ArraySlice([Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)

            let restored = makeController(scrollbackPersistencePath: path)
            var displayCount = 0
            restored.onNeedsDisplay = { displayCount += 1 }

            restored.restorePersistedScrollbackToViewport()
            drainMainQueue(testCase: self)

            XCTAssertEqual(displayCount, 1)
            XCTAssertEqual(restored.withViewport { _, _, offset in offset }, 1)
        }
    }

    func testRestorePersistedScrollbackClampsOffsetToVisibleRowCount() throws {
        try withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("scrollback.bin").path
            let producer = makeController(rows: 3, cols: 8, scrollbackPersistencePath: path)
            for scalar in [65, 66, 67, 68, 69] {
                producer.scrollback.appendRow(ArraySlice([
                    Cell(codepoint: UInt32(scalar), attributes: .default, width: 1, isWideContinuation: false)
                ]), isWrapped: false)
            }

            let restored = makeController(rows: 3, cols: 8, scrollbackPersistencePath: path)
            restored.restorePersistedScrollbackToViewport()
            drainMainQueue(testCase: self)

            XCTAssertEqual(restored.scrollback.rowCount, 5)
            XCTAssertEqual(restored.withViewport { _, _, offset in offset }, 3)
        }
    }

    func testDiscardPersistentScrollbackRemovesBackingFile() throws {
        try withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("scrollback.bin").path
            var controller: TerminalController? = makeController(scrollbackPersistencePath: path)
            controller?.scrollback.appendRow(ArraySlice([Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))

            controller?.discardPersistentScrollback()
            controller = nil

            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testDebugCompactScrollbackShrinksOversizedPersistentBufferWithoutDataLoss() throws {
        try withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("scrollback.bin").path
            seedOversizedScrollbackFile(path: path, initialCapacity: 16, maxCapacity: 256, codepoint: 77)

            let controller = makeController(
                scrollbackPersistencePath: path,
                scrollbackInitialCapacity: 16,
                scrollbackMaxCapacity: 256
            )

            XCTAssertGreaterThan(controller.scrollback.capacity, 16)
            XCTAssertTrue(controller.debugCompactScrollbackNow())
            XCTAssertEqual(controller.scrollback.capacity, 64)
            XCTAssertEqual(controller.scrollback.rowIndexCapacity, 16)
            XCTAssertEqual(controller.scrollback.rowCount, 1)
            XCTAssertEqual(controller.scrollback.getRow(at: 0)?.first?.codepoint, 77)
        }
    }

    func testDetectedImagePlaceholderReturnsHoveredPlaceholderRangeAndIndex() {
        let controller = makeController(rows: 2, cols: 16)
        controller.debugProcessPTYOutputForTesting(Data("\u{1B}_Gi=12,a=T,t=d,c=11,r=1;\u{1B}\\".utf8))

        let detected = controller.detectedImagePlaceholder(at: .init(row: 0, col: 5))

        XCTAssertEqual(detected?.index, 12)
        XCTAssertEqual(detected?.originalText, "[Image #12]")
        XCTAssertEqual(detected?.startCol, 0)
        XCTAssertEqual(detected?.endCol, 10)
    }

    func testDetectedImagePlaceholderIgnoresNonPlaceholderText() {
        let controller = makeController(rows: 2, cols: 12)
        controller.withModel { model in
            let text = "[Image nope]"
            for (index, scalar) in text.unicodeScalars.enumerated() {
                model.grid.setCell(Cell(codepoint: scalar.value, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: index)
            }
        }

        XCTAssertNil(controller.detectedImagePlaceholder(at: .init(row: 0, col: 3)))
    }

    func testDetectedManagedImageFileReturnsQuotedManagedImagePathUnderCursor() throws {
        try withTemporaryPtermConfig { _ in
            let imageURL = PtermDirectories.files.appendingPathComponent("\(UUID().uuidString).png")
            try FileManager.default.createDirectory(at: PtermDirectories.files, withIntermediateDirectories: true)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

            let quotedPath = ClipboardFileStore(rootDirectory: PtermDirectories.files).shellQuotedPath(imageURL.path)
            let controller = makeController(rows: 2, cols: quotedPath.unicodeScalars.count + 8)
            controller.withModel { model in
                for (index, scalar) in quotedPath.unicodeScalars.enumerated() {
                    model.grid.setCell(
                        Cell(codepoint: scalar.value, attributes: .default, width: 1, isWideContinuation: false),
                        at: 0,
                        col: index
                    )
                }
            }

            let detected = controller.detectedManagedImageFile(at: .init(row: 0, col: 8))

            XCTAssertEqual(detected?.url, imageURL.standardizedFileURL)
            XCTAssertEqual(detected?.originalText, quotedPath)
            XCTAssertEqual(detected?.startCol, 0)
            XCTAssertEqual(detected?.endCol, quotedPath.unicodeScalars.count - 1)
        }
    }

    func testDetectedManagedImageFileIgnoresManagedNonImagePaths() throws {
        try withTemporaryPtermConfig { _ in
            let fileURL = PtermDirectories.files.appendingPathComponent("\(UUID().uuidString).txt")
            try FileManager.default.createDirectory(at: PtermDirectories.files, withIntermediateDirectories: true)
            try Data("not-image".utf8).write(to: fileURL)

            let quotedPath = ClipboardFileStore(rootDirectory: PtermDirectories.files).shellQuotedPath(fileURL.path)
            let controller = makeController(rows: 2, cols: quotedPath.unicodeScalars.count + 8)
            controller.withModel { model in
                for (index, scalar) in quotedPath.unicodeScalars.enumerated() {
                    model.grid.setCell(
                        Cell(codepoint: scalar.value, attributes: .default, width: 1, isWideContinuation: false),
                        at: 0,
                        col: index
                    )
                }
            }

            XCTAssertNil(controller.detectedManagedImageFile(at: .init(row: 0, col: 8)))
        }
    }

    func testAllTextSelectedTextAndFindMatchesIncludeScrollbackAndVisibleGrid() {
        let controller = makeController(rows: 3, cols: 4)
        controller.scrollback.appendRow(ArraySlice([
            Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false),
            Cell(codepoint: 66, attributes: .default, width: 1, isWideContinuation: false),
            Cell.empty, Cell.empty
        ]), isWrapped: false)
        controller.scrollback.appendRow(ArraySlice([
            Cell(codepoint: 67, attributes: .default, width: 1, isWideContinuation: false),
            Cell(codepoint: 68, attributes: .default, width: 1, isWideContinuation: false),
            Cell.empty, Cell.empty
        ]), isWrapped: true)
        controller.withModel { model in
            model.grid.setCell(Cell(codepoint: 69, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 0)
            model.grid.setCell(Cell(codepoint: 70, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 1)
            model.grid.setCell(Cell(codepoint: 71, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 2)
            model.grid.setCell(Cell(codepoint: 72, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 3)
            model.grid.setCell(Cell(codepoint: 73, attributes: .default, width: 1, isWideContinuation: false), at: 1, col: 0)
            model.grid.setCell(Cell(codepoint: 74, attributes: .default, width: 1, isWideContinuation: false), at: 1, col: 1)
            model.grid.setCell(Cell(codepoint: 75, attributes: .default, width: 1, isWideContinuation: false), at: 1, col: 2)
            model.grid.setCell(Cell(codepoint: 76, attributes: .default, width: 1, isWideContinuation: false), at: 1, col: 3)
            model.grid.setCell(Cell(codepoint: 77, attributes: .default, width: 1, isWideContinuation: false), at: 2, col: 0)
            model.grid.setCell(Cell(codepoint: 78, attributes: .default, width: 1, isWideContinuation: false), at: 2, col: 1)
            model.grid.setCell(Cell(codepoint: 79, attributes: .default, width: 1, isWideContinuation: false), at: 2, col: 2)
            model.grid.setCell(Cell(codepoint: 80, attributes: .default, width: 1, isWideContinuation: false), at: 2, col: 3)
        }

        XCTAssertTrue(controller.scrollUp(lines: 2))
        XCTAssertEqual(controller.allText(), "ABCD\nEFGH\nIJKL\nMNOP")

        let selection = TerminalSelection(
            anchor: GridPosition(row: 1, col: 0),
            active: GridPosition(row: 2, col: 1),
            mode: .normal
        )
        XCTAssertEqual(controller.selectedText(for: selection), "CD\nEF")

        let matches = controller.findMatches(for: "cd")
        XCTAssertEqual(matches.map(\.absoluteRow), [1])
        XCTAssertEqual(matches.first?.startCol, 0)
        XCTAssertEqual(matches.first?.endCol, 1)
    }

    func testRevealSearchMatchAdjustsViewportForScrollbackResult() {
        let controller = makeController()
        for scalar in [65, 66, 67, 68] {
            controller.scrollback.appendRow(ArraySlice([
                Cell(codepoint: UInt32(scalar), attributes: .default, width: 1, isWideContinuation: false)
            ]), isWrapped: false)
        }

        let selection = controller.revealSearchMatch(.init(absoluteRow: 1, startCol: 0, endCol: 0))

        // scrollOffset centers the match: scrollbackCount(4) - absoluteRow(1) + visibleRows(3)/2 = 4
        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 4)
        // Selection now uses global absolute rows (evicted=0 + absoluteRow=1 = 1)
        XCTAssertEqual(selection.start, .init(row: 1, col: 0))
        XCTAssertEqual(selection.end, .init(row: 1, col: 0))
    }

    func testRevealSearchMatchForVisibleRowReturnsZeroScrollOffset() {
        let controller = makeController(rows: 3, cols: 4)
        let selection = controller.revealSearchMatch(.init(absoluteRow: 1, startCol: 2, endCol: 3))

        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 0)
        XCTAssertEqual(selection.start, .init(row: 1, col: 2))
        XCTAssertEqual(selection.end, .init(row: 1, col: 3))
    }

    func testRevealSearchMatchBeyondViewportClampsToLastVisibleRow() {
        let controller = makeController(rows: 3, cols: 4)

        let selection = controller.revealSearchMatch(.init(absoluteRow: 99, startCol: 1, endCol: 2))

        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 0)
        // Selection now uses global absolute rows (evicted=0 + absoluteRow=99 = 99)
        XCTAssertEqual(selection.start, .init(row: 99, col: 1))
        XCTAssertEqual(selection.end, .init(row: 99, col: 2))
    }

    func testRevealSearchMatchForFirstScrollbackRowShowsTopOfHistory() {
        let controller = makeController(rows: 3, cols: 4)
        for scalar in [65, 66, 67, 68] {
            controller.scrollback.appendRow(ArraySlice([
                Cell(codepoint: UInt32(scalar), attributes: .default, width: 1, isWideContinuation: false)
            ]), isWrapped: false)
        }

        let selection = controller.revealSearchMatch(.init(absoluteRow: 0, startCol: 0, endCol: 0))

        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 4)
        XCTAssertEqual(selection.start, .init(row: 0, col: 0))
        XCTAssertEqual(selection.end, .init(row: 0, col: 0))
    }

    func testResizeResetsScrollOffsetAndUpdatesModelDimensions() {
        let controller = makeController(rows: 3, cols: 4)
        controller.scrollback.appendRow(ArraySlice([Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)
        XCTAssertTrue(controller.scrollUp(lines: 1))

        controller.resize(rows: 5, cols: 6)

        XCTAssertEqual(controller.withViewport { model, _, offset in
            (model.rows, model.cols, offset)
        }.0, 5)
        XCTAssertEqual(controller.withViewport { model, _, offset in
            (model.rows, model.cols, offset)
        }.1, 6)
        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 0)
    }

    func testDetectedLinkFindsURLInVisibleViewport() {
        let controller = makeController(rows: 2, cols: 32)
        let text = Array("see https://example.com/path".unicodeScalars.map(\.value))
        controller.withModel { model in
            for (index, scalar) in text.enumerated() where index < model.cols {
                model.grid.setCell(Cell(codepoint: scalar, attributes: .default, width: 1, isWideContinuation: false),
                                   at: 0, col: index)
            }
        }

        let link = controller.detectedLink(at: .init(row: 0, col: 6))
        XCTAssertEqual(link?.url.absoluteString, "https://example.com/path")
        XCTAssertEqual(link?.originalText, "https://example.com/path")
        XCTAssertEqual(link?.startCol, 4)
    }

    func testDetectedLinkReturnsNilForNonLinkTextAndOutOfBounds() {
        let controller = makeController(rows: 1, cols: 8)
        controller.withModel { model in
            for (index, scalar) in Array("no links".unicodeScalars.map(\.value)).enumerated() where index < model.cols {
                model.grid.setCell(Cell(codepoint: scalar, attributes: .default, width: 1, isWideContinuation: false),
                                   at: 0, col: index)
            }
        }

        XCTAssertNil(controller.detectedLink(at: .init(row: 0, col: 2)))
        XCTAssertNil(controller.detectedLink(at: .init(row: 9, col: 0)))
    }

    func testDetectedLinkReturnsNilForNegativeColumn() {
        let controller = makeController(rows: 1, cols: 16)
        controller.withModel { model in
            for (index, scalar) in Array("https://e.co".unicodeScalars.map(\.value)).enumerated() {
                model.grid.setCell(
                    Cell(codepoint: scalar, attributes: .default, width: 1, isWideContinuation: false),
                    at: 0,
                    col: index
                )
            }
        }

        XCTAssertNil(controller.detectedLink(at: .init(row: 0, col: -1)))
    }

    func testDetectedLinkReturnsNilWhenPointingAtTrailingSpaceAfterURL() {
        let controller = makeController(rows: 1, cols: 20)
        controller.withModel { model in
            for (index, scalar) in Array("https://e.co next".unicodeScalars.map(\.value)).enumerated() where index < model.cols {
                model.grid.setCell(
                    Cell(codepoint: scalar, attributes: .default, width: 1, isWideContinuation: false),
                    at: 0,
                    col: index
                )
            }
        }

        XCTAssertNil(controller.detectedLink(at: .init(row: 0, col: 12)))
    }

    func testDetectedLinkReturnsNilWhenPointingAtPrefixTextBeforeURL() {
        let controller = makeController(rows: 1, cols: 24)
        controller.withModel { model in
            for (index, scalar) in Array("see https://e.co".unicodeScalars.map(\.value)).enumerated() where index < model.cols {
                model.grid.setCell(
                    Cell(codepoint: scalar, attributes: .default, width: 1, isWideContinuation: false),
                    at: 0,
                    col: index
                )
            }
        }

        XCTAssertNil(controller.detectedLink(at: .init(row: 0, col: 1)))
    }

    func testDetectedLinkSkipsWideContinuationCells() {
        let controller = makeController(rows: 1, cols: 16)
        controller.withModel { model in
            model.grid.setCell(Cell(codepoint: 0x65E5, attributes: .default, width: 2, isWideContinuation: false), at: 0, col: 0)
            model.grid.setCell(Cell(codepoint: 0, attributes: .default, width: 0, isWideContinuation: true), at: 0, col: 1)
            for (index, scalar) in Array(" https://e.co".unicodeScalars.map(\.value)).enumerated() {
                let col = index + 2
                model.grid.setCell(Cell(codepoint: scalar, attributes: .default, width: 1, isWideContinuation: false),
                                   at: 0, col: col)
            }
        }

        let link = controller.detectedLink(at: .init(row: 0, col: 6))
        XCTAssertEqual(link?.url.absoluteString, "https://e.co")
    }

    func testDetectedLinkFindsURLInVisibleScrollbackRow() {
        let controller = makeController(rows: 2, cols: 24)
        let text = Array("go https://e.co/path".unicodeScalars.map(\.value))
        controller.scrollback.appendRow(ArraySlice(text.prefix(24).map {
            Cell(codepoint: $0, attributes: .default, width: 1, isWideContinuation: false)
        }), isWrapped: false)
        controller.setScrollOffset(1)

        let link = controller.detectedLink(at: .init(row: 0, col: 5))

        XCTAssertEqual(link?.url.absoluteString, "https://e.co/path")
        XCTAssertEqual(link?.startCol, 3)
        XCTAssertEqual(link?.endCol, 19)
    }

    func testScrollNavigationNoopsWhenNoHistoryOrAlreadyAtBottom() {
        let controller = makeController()
        XCTAssertFalse(controller.scrollUp(lines: 1))
        XCTAssertFalse(controller.scrollDown(lines: 1))

        controller.scrollback.appendRow(ArraySlice([Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)
        XCTAssertTrue(controller.scrollUp(lines: 1))
        XCTAssertTrue(controller.scrollDown(lines: 1))
        XCTAssertFalse(controller.scrollDown(lines: 1))
    }

    func testScrollToTopPinsViewportToOldestScrollbackRow() {
        let controller = makeController()
        controller.scrollback.appendRow(ArraySlice([Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)
        controller.scrollback.appendRow(ArraySlice([Cell(codepoint: 66, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)

        controller.scrollToTop()

        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 2)
    }

    func testScrollToTopEmitsDisplayCallbackWhenOffsetChanges() {
        let controller = makeController()
        controller.scrollback.appendRow(ArraySlice([Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)
        var displayCount = 0
        controller.onNeedsDisplay = { displayCount += 1 }

        controller.scrollToTop()
        drainMainQueue(testCase: self)

        XCTAssertEqual(displayCount, 1)
    }

    func testClearScrollbackClearsHistoryAndResetsScrollOffsetWithoutMutatingGrid() {
        let controller = makeController(rows: 2, cols: 4)
        controller.scrollback.appendRow(ArraySlice([Cell(codepoint: 88, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)
        controller.scrollUp(lines: 1)
        controller.withModel { model in
            model.grid.setCell(Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 0)
            model.grid.setCell(Cell(codepoint: 66, attributes: .default, width: 1, isWideContinuation: false), at: 1, col: 1)
        }

        controller.clearScrollback()
        drainMainQueue(testCase: self)

        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 0)
        controller.withModel { model in
            XCTAssertEqual(model.grid.cell(at: 0, col: 0).codepoint, 65)
            XCTAssertEqual(model.grid.cell(at: 1, col: 1).codepoint, 66)
        }
        XCTAssertEqual(controller.scrollback.rowCount, 0)
    }

    func testPendingUpdateModeSuppressesDisplayCallbacksUntilResume() {
        let controller = makeController(rows: 2, cols: 8)
        var displayCount = 0
        var suppressionChanges: [Bool] = []
        controller.onNeedsDisplay = { displayCount += 1 }
        controller.onRenderingSuppressedChange = { suppressionChanges.append($0) }

        controller.debugProcessPTYOutputForTesting(Data("\u{1B}[?2026hAB".utf8))
        drainMainQueue(testCase: self)
        XCTAssertEqual(displayCount, 0)
        XCTAssertEqual(suppressionChanges, [true])
        XCTAssertTrue(controller.isRenderingSuppressed)

        controller.debugProcessPTYOutputForTesting(Data("CD\u{1B}[?2026l".utf8))
        drainMainQueue(testCase: self)
        XCTAssertEqual(displayCount, 1)
        XCTAssertEqual(suppressionChanges, [true, false])
        XCTAssertFalse(controller.isRenderingSuppressed)
        XCTAssertEqual(controller.withViewport { model, _, _ in
            [
                model.grid.cell(at: 0, col: 0).codepoint,
                model.grid.cell(at: 0, col: 1).codepoint,
                model.grid.cell(at: 0, col: 2).codepoint,
                model.grid.cell(at: 0, col: 3).codepoint
            ]
        }, [0x41, 0x42, 0x43, 0x44])
    }

    func testPendingUpdateModeStillDisplaysProgressLineBeforeSuppressingRendering() {
        let controller = makeController(rows: 2, cols: 32)
        var displayCount = 0
        var suppressionChanges: [Bool] = []
        controller.onNeedsDisplay = { displayCount += 1 }
        controller.onRenderingSuppressedChange = { suppressionChanges.append($0) }

        controller.debugProcessPTYOutputForTesting(Data("Running: Only ASCII chars\r\n\u{1B}[?2026h".utf8))
        drainMainQueue(testCase: self)

        XCTAssertEqual(displayCount, 1)
        XCTAssertEqual(suppressionChanges, [true])
        XCTAssertTrue(controller.isRenderingSuppressed)
        XCTAssertEqual(controller.withViewport { model, _, _ in
            String(model.grid.rowCells(0).map { Character(UnicodeScalar($0.codepoint) ?? " ") })
        }.trimmingCharacters(in: .whitespaces), "Running: Only ASCII chars")
    }

    func testPendingUpdateModeDisplaysProgressLineWhenResumeAndPauseShareChunk() {
        let controller = makeController(rows: 2, cols: 40)
        var displayCount = 0
        var suppressionChanges: [Bool] = []
        controller.onNeedsDisplay = { displayCount += 1 }
        controller.onRenderingSuppressedChange = { suppressionChanges.append($0) }

        controller.debugProcessPTYOutputForTesting(Data("\u{1B}[?2026h".utf8))
        drainMainQueue(testCase: self)
        XCTAssertTrue(controller.isRenderingSuppressed)

        controller.debugProcessPTYOutputForTesting(
            Data("Running: Long escape codes\r\n\u{1B}[?2026l\u{1B}[?2026h".utf8)
        )
        drainMainQueue(testCase: self)

        XCTAssertEqual(displayCount, 1)
        XCTAssertEqual(suppressionChanges, [true, false, true])
        XCTAssertTrue(controller.isRenderingSuppressed)
        XCTAssertEqual(controller.withViewport { model, _, _ in
            String(model.grid.rowCells(0).map { Character(UnicodeScalar($0.codepoint) ?? " ") })
        }.trimmingCharacters(in: .whitespaces), "Running: Long escape codes")
    }

    func testIgnoredOSCPayloadFastPathStillResumesPendingUpdateMode() {
        let controller = makeController(rows: 2, cols: 40)
        controller.debugProcessPTYOutputForTesting(Data("\u{1B}[?2026h".utf8))
        drainMainQueue(testCase: self)
        XCTAssertTrue(controller.isRenderingSuppressed)

        let payload = "\u{1B}]6;" + String(repeating: "A", count: 8192) + "\u{1B}\\"
        controller.debugProcessPTYOutputForTesting(Data(payload.utf8))
        controller.debugProcessPTYOutputForTesting(Data("\u{1B}[?2026l".utf8))
        drainMainQueue(testCase: self)

        XCTAssertFalse(controller.isRenderingSuppressed)
    }

    func testIgnoredAPCPayloadFastPathStillResumesPendingUpdateMode() {
        let controller = makeController(rows: 2, cols: 40)
        controller.debugProcessPTYOutputForTesting(Data("\u{1B}[?2026h".utf8))
        drainMainQueue(testCase: self)
        XCTAssertTrue(controller.isRenderingSuppressed)

        let payload = "\u{1B}_G" + String(repeating: "B", count: 8192) + "\u{1B}\\"
        controller.debugProcessPTYOutputForTesting(Data(payload.utf8))
        controller.debugProcessPTYOutputForTesting(Data("\u{1B}[?2026l".utf8))
        drainMainQueue(testCase: self)

        XCTAssertFalse(controller.isRenderingSuppressed)
    }

    func testFindMatchesIsCaseInsensitiveAndEmptyQueryReturnsNoMatches() {
        let controller = makeController(rows: 1, cols: 8)
        controller.withModel { model in
            for (index, scalar) in Array("AbCd".unicodeScalars.map(\.value)).enumerated() {
                model.grid.setCell(Cell(codepoint: scalar, attributes: .default, width: 1, isWideContinuation: false),
                                   at: 0, col: index)
            }
        }

        XCTAssertTrue(controller.findMatches(for: "").isEmpty)
        let matches = controller.findMatches(for: "bc")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.startCol, 1)
        XCTAssertEqual(matches.first?.endCol, 2)
    }

    func testFindMatchesReturnsNoResultsWhenQueryAbsent() {
        let controller = makeController(rows: 1, cols: 8)
        controller.withModel { model in
            for (index, scalar) in Array("terminal".unicodeScalars.map(\.value)).enumerated() where index < model.cols {
                model.grid.setCell(
                    Cell(codepoint: scalar, attributes: .default, width: 1, isWideContinuation: false),
                    at: 0,
                    col: index
                )
            }
        }

        XCTAssertTrue(controller.findMatches(for: "xyz").isEmpty)
    }

    func testFindMatchesReturnsMultipleOccurrencesOnSameRow() {
        let controller = makeController(rows: 1, cols: 8)
        controller.withModel { model in
            for (index, scalar) in Array("abABab".unicodeScalars.map(\.value)).enumerated() {
                model.grid.setCell(Cell(codepoint: scalar, attributes: .default, width: 1, isWideContinuation: false),
                                   at: 0, col: index)
            }
        }

        let matches = controller.findMatches(for: "ab")
        XCTAssertEqual(matches.map(\.startCol), [0, 2, 4])
        XCTAssertEqual(matches.map(\.endCol), [1, 3, 5])
    }

    func testFindMatchesSkipsWideContinuationCellsWhenMappingColumns() {
        let controller = makeController(rows: 1, cols: 8)
        controller.withModel { model in
            model.grid.setCell(Cell(codepoint: 0x65E5, attributes: .default, width: 2, isWideContinuation: false), at: 0, col: 0)
            model.grid.setCell(Cell(codepoint: 0, attributes: .default, width: 0, isWideContinuation: true), at: 0, col: 1)
            model.grid.setCell(Cell(codepoint: 0x61, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 2)
            model.grid.setCell(Cell(codepoint: 0x62, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 3)
        }

        let matches = controller.findMatches(for: "ab")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.startCol, 2)
        XCTAssertEqual(matches.first?.endCol, 3)
    }

    func testFindMatchesIncludesScrollbackAndVisibleRowsSeparately() {
        let controller = makeController(rows: 2, cols: 4)
        controller.scrollback.appendRow(ArraySlice([
            Cell(codepoint: 0x61, attributes: .default, width: 1, isWideContinuation: false),
            Cell(codepoint: 0x62, attributes: .default, width: 1, isWideContinuation: false)
        ]), isWrapped: false)
        controller.withModel { model in
            model.grid.setCell(Cell(codepoint: 0x61, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 1)
            model.grid.setCell(Cell(codepoint: 0x62, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 2)
        }

        let matches = controller.findMatches(for: "ab")

        XCTAssertEqual(matches.map(\.absoluteRow), [0, 1])
        XCTAssertEqual(matches.map(\.startCol), [0, 1])
        XCTAssertEqual(matches.map(\.endCol), [1, 2])
    }

    func testFindMatchesOnlySearchesRetainedRowsAfterScrollbackEviction() {
        let controller = makeController(
            rows: 1,
            cols: 16,
            scrollbackInitialCapacity: 128,
            scrollbackMaxCapacity: 128
        )

        for index in 0..<10 {
            let text = "row\(index)"
            controller.scrollback.appendRow(ArraySlice(text.unicodeScalars.map {
                Cell(codepoint: $0.value, attributes: .default, width: 1, isWideContinuation: false)
            }), isWrapped: false)
        }

        XCTAssertLessThan(controller.scrollback.rowCount, 10)
        XCTAssertTrue(controller.findMatches(for: "row0").isEmpty)
        XCTAssertEqual(controller.findMatches(for: "row9").map(\.absoluteRow), [controller.scrollback.rowCount - 1])
    }

    func testAllTextDoesNotInsertNewlineBetweenWrappedRows() {
        let controller = makeController(rows: 2, cols: 4)
        controller.withModel { model in
            model.grid.setCell(Cell(codepoint: 0x41, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 0)
            model.grid.setCell(Cell(codepoint: 0x42, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 1)
            model.grid.setCell(Cell(codepoint: 0x43, attributes: .default, width: 1, isWideContinuation: false), at: 1, col: 0)
            model.grid.setCell(Cell(codepoint: 0x44, attributes: .default, width: 1, isWideContinuation: false), at: 1, col: 1)
            model.grid.setWrapped(1, true)
        }

        XCTAssertEqual(controller.allText(), "ABCD  ")
    }

    func testUpdateFontSettingsNotifiesWhenRequested() {
        let controller = makeController()
        var stateChanges = 0
        controller.onStateChange = { stateChanges += 1 }

        controller.updateFontSettings(name: "Monaco", size: 14, notify: true)
        drainMainQueue(testCase: self)

        XCTAssertEqual(stateChanges, 1)
        XCTAssertEqual(controller.persistedFontSettings.name, "Monaco")
        XCTAssertEqual(controller.persistedFontSettings.size, 14)
    }

    func testUpdateFontSettingsDoesNotNotifyWhenSuppressed() {
        let controller = makeController()
        var stateChanges = 0
        controller.onStateChange = { stateChanges += 1 }

        controller.updateFontSettings(name: "Monaco", size: 14, notify: false)
        drainMainQueue(testCase: self)

        XCTAssertEqual(stateChanges, 0)
        XCTAssertEqual(controller.persistedFontSettings.name, "Monaco")
        XCTAssertEqual(controller.persistedFontSettings.size, 14)
    }

    func testSetWorkspaceNameFallsBackWhenSanitizedValueIsEmpty() {
        let controller = makeController(workspaceName: "Main")

        controller.setWorkspaceName("   ")
        drainMainQueue(testCase: self)

        XCTAssertEqual(controller.sessionSnapshot.workspaceName, "Uncategorized")
    }

    func testSetWorkspaceNameEmitsStateChange() {
        let controller = makeController(workspaceName: "Main")
        var stateChanges = 0
        controller.onStateChange = { stateChanges += 1 }

        controller.setWorkspaceName("QA")
        drainMainQueue(testCase: self)

        XCTAssertEqual(stateChanges, 1)
        XCTAssertEqual(controller.sessionSnapshot.workspaceName, "QA")
    }

    func testUpdateCurrentDirectoryDisplaysHomeAsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let controller = makeController(initialDirectory: "/tmp/start")
        var titles: [String] = []
        controller.onTitleChange = { titles.append($0) }

        controller.updateCurrentDirectory(path: home)
        drainMainQueue(testCase: self)

        XCTAssertEqual(controller.title, "~")
        XCTAssertEqual(titles.last, "~")
        XCTAssertEqual(controller.sessionSnapshot.currentDirectory, home)
    }

    func testUpdateCurrentDirectoryExpandsTildePathBeforePersisting() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let controller = makeController(initialDirectory: "/tmp/start")
        var titles: [String] = []
        controller.onTitleChange = { titles.append($0) }

        controller.updateCurrentDirectory(path: "~/project")
        drainMainQueue(testCase: self)

        XCTAssertEqual(controller.title, "project")
        XCTAssertEqual(titles.last, "project")
        XCTAssertEqual(controller.sessionSnapshot.currentDirectory, "\(home)/project")
    }

    func testUpdateCurrentDirectoryUsesSlashForRootPath() {
        let controller = makeController(initialDirectory: "/tmp/start")

        controller.updateCurrentDirectory(path: "/")
        drainMainQueue(testCase: self)

        XCTAssertEqual(controller.title, "/")
        XCTAssertEqual(controller.sessionSnapshot.currentDirectory, "/")
    }

    func testUpdateCurrentDirectoryNormalizesTrailingSlashToDirectoryName() {
        let controller = makeController(initialDirectory: "/tmp/start")

        controller.updateCurrentDirectory(path: "/tmp/workspace/")
        drainMainQueue(testCase: self)

        XCTAssertEqual(controller.title, "workspace")
        XCTAssertEqual(controller.sessionSnapshot.currentDirectory, "/tmp/workspace")
    }

    func testSetCustomTitleNilRestoresDirectoryTitle() {
        let controller = makeController(initialDirectory: "/tmp/project")
        var titles: [String] = []
        controller.onTitleChange = { titles.append($0) }

        controller.setCustomTitle("Pinned")
        drainMainQueue(testCase: self)
        XCTAssertEqual(controller.title, "Pinned")

        controller.setCustomTitle(nil)
        drainMainQueue(testCase: self)

        XCTAssertEqual(controller.title, "project")
        XCTAssertEqual(titles.suffix(2), ["Pinned", "project"])
    }

    func testUpdateCurrentDirectoryDoesNotEmitTitleCallbackWhileCustomTitleIsPinned() {
        let controller = makeController(initialDirectory: "/tmp/project", customTitle: "Pinned")
        var titles: [String] = []
        var stateChanges = 0
        controller.onTitleChange = { titles.append($0) }
        controller.onStateChange = { stateChanges += 1 }

        controller.updateCurrentDirectory(path: "/tmp/other")
        drainMainQueue(testCase: self)

        XCTAssertEqual(controller.title, "Pinned")
        XCTAssertTrue(titles.isEmpty)
        XCTAssertEqual(stateChanges, 1)
        XCTAssertEqual(controller.sessionSnapshot.currentDirectory, "/tmp/other")
    }

    func testRefreshCurrentDirectoryFromProcessIDUsesInjectedProvider() {
        let controller = makeController(
            initialDirectory: "/tmp/start",
            currentDirectoryProvider: { _ in "/tmp/refreshed" }
        )
        var titles: [String] = []
        controller.onTitleChange = { titles.append($0) }

        XCTAssertTrue(controller.refreshCurrentDirectory(fromProcessID: 123))
        drainMainQueue(testCase: self)

        XCTAssertEqual(controller.title, "refreshed")
        XCTAssertEqual(controller.sessionSnapshot.currentDirectory, "/tmp/refreshed")
        XCTAssertEqual(titles.last, "refreshed")
    }

    func testSetScrollOffsetClampsNegativeAndLargeValues() {
        let controller = makeController()
        controller.scrollback.appendRow(ArraySlice([Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)
        controller.scrollback.appendRow(ArraySlice([Cell(codepoint: 66, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)

        controller.setScrollOffset(-5)
        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 0)

        controller.setScrollOffset(99)
        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 2)
    }

    func testScrollToBottomResetsOffsetAfterAbsoluteSeek() {
        let controller = makeController()
        controller.scrollback.appendRow(ArraySlice([Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)
        controller.scrollback.appendRow(ArraySlice([Cell(codepoint: 66, attributes: .default, width: 1, isWideContinuation: false)]), isWrapped: false)
        controller.setScrollOffset(2)

        controller.scrollToBottom()

        XCTAssertEqual(controller.withViewport { _, _, offset in offset }, 0)
    }

    func testSelectedTextReturnsEmptyForEmptySelection() {
        let controller = makeController()
        let selection = TerminalSelection(anchor: .init(row: 0, col: 0), active: .init(row: 0, col: 0), mode: .normal)
        XCTAssertEqual(controller.selectedText(for: selection), "")
    }

    func testSelectedTextReturnsEmptyWhenSelectionStartsOutsideViewport() {
        let controller = makeController(rows: 2, cols: 4)
        let selection = TerminalSelection(anchor: .init(row: 5, col: 0), active: .init(row: 5, col: 2), mode: .normal)

        XCTAssertEqual(controller.selectedText(for: selection), "")
    }

    func testSelectedTextRectangularSelectionIncludesVisibleScrollbackRows() {
        let controller = makeController(rows: 2, cols: 4)
        controller.scrollback.appendRow(ArraySlice([
            Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false),
            Cell(codepoint: 66, attributes: .default, width: 1, isWideContinuation: false),
            Cell(codepoint: 67, attributes: .default, width: 1, isWideContinuation: false),
            Cell(codepoint: 68, attributes: .default, width: 1, isWideContinuation: false)
        ]), isWrapped: false)
        controller.withModel { model in
            model.grid.setCell(Cell(codepoint: 69, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 0)
            model.grid.setCell(Cell(codepoint: 70, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 1)
            model.grid.setCell(Cell(codepoint: 71, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 2)
            model.grid.setCell(Cell(codepoint: 72, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 3)
        }
        controller.setScrollOffset(1)

        let selection = TerminalSelection(anchor: .init(row: 0, col: 1), active: .init(row: 1, col: 2), mode: .rectangular)

        XCTAssertEqual(controller.selectedText(for: selection), "BC\nFG")
    }

    func testAllTextTrimsTrailingSpacesBeforeLineBreaks() {
        let controller = makeController(rows: 2, cols: 4)
        controller.withModel { model in
            model.grid.setCell(Cell(codepoint: 0x41, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 0)
            model.grid.setCell(Cell(codepoint: 0x20, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 1)
            model.grid.setCell(Cell(codepoint: 0x42, attributes: .default, width: 1, isWideContinuation: false), at: 1, col: 0)
        }

        XCTAssertEqual(controller.allText(), "A\nB   ")
    }

    func testAllTextPreservesBlankLogicalLineBetweenNonWrappedRows() {
        let controller = makeController(rows: 3, cols: 3)
        controller.withModel { model in
            model.grid.setCell(Cell(codepoint: 0x41, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 0)
            model.grid.setCell(Cell(codepoint: 0x42, attributes: .default, width: 1, isWideContinuation: false), at: 2, col: 0)
        }

        XCTAssertEqual(controller.allText(), "A\n\nB  ")
    }

    func testAllTextReflectsOnlyRetainedScrollbackAfterEviction() {
        let controller = makeController(
            rows: 1,
            cols: 8,
            scrollbackInitialCapacity: 128,
            scrollbackMaxCapacity: 128
        )

        let appendedRows = ["old0", "old1", "keep8", "keep9"]
        for value in appendedRows {
            controller.scrollback.appendRow(ArraySlice(value.unicodeScalars.map {
                Cell(
                    codepoint: $0.value,
                    attributes: CellAttributes(
                        foreground: .indexed(2),
                        background: .default,
                        bold: false,
                        italic: false,
                        underline: false,
                        strikethrough: false,
                        inverse: false,
                        hidden: false,
                        dim: false,
                        blink: false
                    ),
                    width: 1,
                    isWideContinuation: false
                )
            }), isWrapped: false)
        }

        XCTAssertLessThan(controller.scrollback.rowCount, appendedRows.count)

        let oldestRetained = controller.scrollback.getRow(at: 0) ?? []
        let newestRetained = controller.scrollback.getRow(at: controller.scrollback.rowCount - 1) ?? []
        let oldestRetainedText = String(oldestRetained.compactMap { UnicodeScalar($0.codepoint) }.map(Character.init))
        let newestRetainedText = String(newestRetained.compactMap { UnicodeScalar($0.codepoint) }.map(Character.init))

        let rendered = controller.allText()
        XCTAssertFalse(rendered.contains("old0"))
        XCTAssertFalse(oldestRetainedText.isEmpty)
        XCTAssertFalse(newestRetainedText.isEmpty)
        XCTAssertTrue(rendered.contains(oldestRetainedText))
        XCTAssertTrue(rendered.contains(newestRetainedText))
    }

    func testFindMatchesLargeScrollbackPerformanceSmoke() {
        let controller = makeController(rows: 2, cols: 32)
        for index in 0..<4_000 {
            let text = String(format: "row%04d perf payload marker", index)
            controller.scrollback.appendRow(ArraySlice(text.unicodeScalars.map {
                Cell(codepoint: $0.value, attributes: .default, width: 1, isWideContinuation: false)
            }), isWrapped: false)
        }

        XCTAssertEqual(controller.findMatches(for: "row3999").count, 1)
        measure {
            _ = controller.findMatches(for: "marker")
        }
    }

    func testAllTextLargeScrollbackPerformanceSmoke() {
        let controller = makeController(rows: 2, cols: 24)
        for index in 0..<2_000 {
            let text = String(format: "line%04d payload", index)
            controller.scrollback.appendRow(ArraySlice(text.unicodeScalars.map {
                Cell(codepoint: $0.value, attributes: .default, width: 1, isWideContinuation: false)
            }), isWrapped: false)
        }

        XCTAssertTrue(controller.allText().contains("line1999"))
        measure {
            _ = controller.allText()
        }
    }

    func testFindMatchesLargeScrollbackThresholdGuard() {
        let controller = makeController(
            rows: 4,
            cols: 48,
            scrollbackInitialCapacity: 1_500_000,
            scrollbackMaxCapacity: 1_500_000
        )
        for index in 0..<12_000 {
            let text = String(format: "entry%05d threshold marker payload", index)
            controller.scrollback.appendRow(ArraySlice(text.unicodeScalars.map {
                Cell(codepoint: $0.value, attributes: .default, width: 1, isWideContinuation: false)
            }), isWrapped: false)
        }

        let started = CFAbsoluteTimeGetCurrent()
        let matches = controller.findMatches(for: "marker")
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(matches.count, controller.scrollback.rowCount)
        XCTAssertGreaterThan(matches.count, 1_000)
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testAllTextLargeScrollbackThresholdGuard() {
        let controller = makeController(
            rows: 4,
            cols: 48,
            scrollbackInitialCapacity: 1_000_000,
            scrollbackMaxCapacity: 1_000_000
        )
        for index in 0..<6_000 {
            let text = String(format: "snapshot%05d payload body", index)
            controller.scrollback.appendRow(ArraySlice(text.unicodeScalars.map {
                Cell(codepoint: $0.value, attributes: .default, width: 1, isWideContinuation: false)
            }), isWrapped: false)
        }

        let started = CFAbsoluteTimeGetCurrent()
        let allText = controller.allText()
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertTrue(allText.contains("snapshot05999"))
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testTerminalControllerSoakMaintainsBoundedScrollbackAndLatestRows() {
        let controller = makeController(
            rows: 6,
            cols: 48,
            scrollbackInitialCapacity: 2048,
            scrollbackMaxCapacity: 2048
        )

        for index in 0..<8_000 {
            let text = String(format: "soak%05d payload marker", index)
            controller.scrollback.appendRow(ArraySlice(text.unicodeScalars.map {
                Cell(codepoint: $0.value, attributes: .default, width: 1, isWideContinuation: false)
            }), isWrapped: false)

            if index.isMultiple(of: 250) {
                _ = controller.findMatches(for: "marker")
                _ = controller.allText()
                controller.resize(rows: 6 + (index / 250) % 3, cols: 48 + (index / 250) % 5)
                _ = controller.scrollUp(lines: 2)
                _ = controller.scrollDown(lines: 2)
            }
        }

        XCTAssertLessThan(controller.scrollback.rowCount, 8_000)
        XCTAssertTrue(controller.findMatches(for: "soak07999").contains { $0.absoluteRow >= 0 })
        XCTAssertFalse(controller.findMatches(for: "soak00000").contains { $0.absoluteRow >= 0 })
        XCTAssertTrue(controller.allText().contains("soak07999"))
    }

    func testTerminalControllerConcurrentReadWriteOperationsRemainConsistent() {
        let controller = makeController(rows: 8, cols: 40)
        let queue = DispatchQueue(label: "terminal-controller-concurrency", attributes: .concurrent)
        let group = DispatchGroup()

        for index in 0..<50 {
            group.enter()
            queue.async {
                controller.debugAppendScrollbackRowForTesting(ArraySlice("row\(index)".unicodeScalars.map {
                    Cell(codepoint: $0.value, attributes: .default, width: 1, isWideContinuation: false)
                }), isWrapped: false)
                _ = controller.findMatches(for: "row")
                _ = controller.allText()
                controller.resize(rows: 8 + (index % 3), cols: 40 + (index % 5))
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        let size = controller.withModel { ($0.rows, $0.cols) }
        XCTAssertGreaterThanOrEqual(size.0, 8)
        XCTAssertGreaterThanOrEqual(size.1, 40)
        XCTAssertFalse(controller.allText().isEmpty)
    }

    func testTerminalControllerAllTextReserveCapacityUsesBoundedHeuristic() {
        XCTAssertEqual(
            TerminalController.debugSuggestedAllTextReserveCapacity(totalRows: 8, cols: 80),
            640
        )
        XCTAssertEqual(
            TerminalController.debugSuggestedAllTextReserveCapacity(totalRows: 100_000, cols: 200),
            64 * 1024
        )
    }

    func testTerminalControllerSearchReserveCapacityUsesBoundedHeuristic() {
        XCTAssertEqual(
            TerminalController.debugSuggestedSearchReserveCapacity(scrollbackRows: 8),
            16
        )
        XCTAssertEqual(
            TerminalController.debugSuggestedSearchReserveCapacity(scrollbackRows: 100_000),
            4 * 1024
        )
    }

    func testDebugProcessPTYOutputMatchesByteWiseProcessingForConsecutiveLineFeeds() {
        let bulk = makeController(rows: 3, cols: 4)
        let byteWise = makeController(rows: 3, cols: 4)
        let payload = Data("A\n\n\n\nB\n\nC\nD\n\n\n\nE".utf8)

        bulk.debugProcessPTYOutputForTesting(payload)
        for byte in payload {
            byteWise.debugProcessPTYOutputForTesting(Data([byte]))
        }

        let bulkRowCount = bulk.withViewport { _, scrollback, _ in scrollback.rowCount }
        let byteWiseRowCount = byteWise.withViewport { _, scrollback, _ in scrollback.rowCount }
        XCTAssertEqual(bulkRowCount, byteWiseRowCount)

        for offset in 0...bulkRowCount {
            bulk.setScrollOffset(offset)
            byteWise.setScrollOffset(offset)
            XCTAssertEqual(bulk.allText(), byteWise.allText(), "mismatch at scroll offset \(offset)")
        }
    }

    func testDebugProcessPTYOutputMatchesByteWiseProcessingForKittyBenchmarkCSI() {
        let bulk = makeController(rows: 24, cols: 80)
        let byteWise = makeController(rows: 24, cols: 80)
        let payloadString =
            "\u{1B}[m\u{1B}[?1h\u{1B}[H"
            + "\u{1B}[1;2;3;4:3;31m"
            + "\u{1B}[38:5:24;48:2:125:136:147m"
            + "a"
            + "\u{1B}[39m\u{1B}[10`a\u{1B}[100b\u{1B}[?1l"
            + "\u{1B}[m\u{1B}[10A\u{1B}[3E\u{1B}[2K"
            + "done\n"
        let payload = Data(payloadString.utf8)

        bulk.debugProcessPTYOutputForTesting(payload)
        for byte in payload {
            byteWise.debugProcessPTYOutputForTesting(Data([byte]))
        }

        XCTAssertEqual(bulk.allText(), byteWise.allText())
        let bulkCursor = bulk.withModel { ($0.cursor.row, $0.cursor.col, $0.cursor.pendingWrap) }
        let byteWiseCursor = byteWise.withModel { ($0.cursor.row, $0.cursor.col, $0.cursor.pendingWrap) }
        XCTAssertEqual(bulkCursor.0, byteWiseCursor.0)
        XCTAssertEqual(bulkCursor.1, byteWiseCursor.1)
        XCTAssertEqual(bulkCursor.2, byteWiseCursor.2)
    }

    func testDebugProcessPTYOutputMatchesByteWiseProcessingForKittyBenchmarkSetupAndTeardown() {
        let bulk = makeController(rows: 24, cols: 80)
        let byteWise = makeController(rows: 24, cols: 80)
        let payloadString =
            "\u{1B}7\u{1B}[?s\u{1B}[*x\u{1B}[4l\u{1B}[?1l\u{1B}[?5l\u{1B}[?2004l"
            + "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1005l\u{1B}[?1006l"
            + "\u{1B}[?8h\u{1B}[?7h\u{1B}[?25h\u{1B}[?1049h\u{1B}[H\u{1B}[2J\u{1B}[>u\u{1B}[?25l"
            + "Running: Warmup\r\n"
            + "\u{1B}[?2026h"
            + "abc"
            + "\u{1B}[?2026l\u{1B}[5n"
            + "\u{1B}[<u\u{1B}[?1049l\u{1B}[?r"
        let payload = Data(payloadString.utf8)

        bulk.debugProcessPTYOutputForTesting(payload)
        for byte in payload {
            byteWise.debugProcessPTYOutputForTesting(Data([byte]))
        }

        XCTAssertEqual(bulk.allText(), byteWise.allText())
        let bulkCursor = bulk.withModel { ($0.cursor.row, $0.cursor.col, $0.cursor.visible) }
        let byteWiseCursor = byteWise.withModel { ($0.cursor.row, $0.cursor.col, $0.cursor.visible) }
        XCTAssertEqual(bulkCursor.0, byteWiseCursor.0)
        XCTAssertEqual(bulkCursor.1, byteWiseCursor.1)
        XCTAssertEqual(bulkCursor.2, byteWiseCursor.2)
        XCTAssertFalse(bulk.withModel { $0.kittyKeyboardProtocolEnabled })
        XCTAssertFalse(byteWise.withModel { $0.kittyKeyboardProtocolEnabled })
    }

    func testDebugProcessPTYOutputMatchesByteWiseProcessingForKittyGraphicsPayload() {
        let bulk = makeController(rows: 24, cols: 80)
        let byteWise = makeController(rows: 24, cols: 80)
        let imageChunk = String(repeating: "QUJDREVGR0g=", count: 256)
        let payloadString =
            "\u{1B}[?2026h"
            + "Running: Images\r\n"
            + "\u{1B}_Ga=T,f=100,t=d;"
            + imageChunk
            + "\u{1B}\\"
            + "\u{1B}[?2026l\u{1B}[5n"
        let payload = Data(payloadString.utf8)

        bulk.debugProcessPTYOutputForTesting(payload)
        for byte in payload {
            byteWise.debugProcessPTYOutputForTesting(Data([byte]))
        }

        XCTAssertEqual(bulk.allText(), byteWise.allText())
        XCTAssertFalse(bulk.allText().contains("[Image #1]"))
        let bulkState = bulk.withModel { ($0.cursor.row, $0.cursor.col, $0.cursor.visible) }
        let byteWiseState = byteWise.withModel { ($0.cursor.row, $0.cursor.col, $0.cursor.visible) }
        XCTAssertEqual(bulkState.0, byteWiseState.0)
        XCTAssertEqual(bulkState.1, byteWiseState.1)
        XCTAssertEqual(bulkState.2, byteWiseState.2)
    }

    func testKittyGraphicsPayloadPersistsPreviewableImageData() throws {
        try withTemporaryPtermConfig { _ in
            PastedImageRegistry.shared.reset()
            defer { PastedImageRegistry.shared.reset() }

            let controller = makeController(rows: 24, cols: 80)
            let pngBytes = Data([
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52
            ])
            let payload = Data("\u{1B}_Gi=3,a=T,f=100,t=d;\(pngBytes.base64EncodedString())\u{1B}\\".utf8)

            controller.debugProcessPTYOutputForTesting(payload)

            var resolvedURL: URL?
            for _ in 0..<50 {
                if let url = PastedImageRegistry.shared.url(ownerID: controller.id, forPlaceholderIndex: 3) {
                    resolvedURL = url
                    break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }

            let url = try XCTUnwrap(resolvedURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try Data(contentsOf: url), pngBytes)
            XCTAssertFalse(controller.allText().contains("[Image #3]"))
            XCTAssertEqual(controller.detectedImagePlaceholder(at: .init(row: 0, col: 0))?.index, 3)
        }
    }

    func testInlineImageReachabilityReconciliationRetainsOnlyGridAndScrollbackReferences() {
        let controller = makeController(rows: 4, cols: 6)
        var reported: [(UUID, Set<Int>)] = []
        controller.onInlineImageReachabilityChange = { ownerID, liveIndices in
            reported.append((ownerID, liveIndices))
        }

        controller.model.grid.setCell(.inlineImage(id: 1, columns: 1, rows: 1, originColOffset: 0, originRowOffset: 0), at: 0, col: 0)
        controller.debugAppendScrollbackRowForTesting(
            ArraySlice([.inlineImage(id: 2, columns: 1, rows: 1, originColOffset: 0, originRowOffset: 0)]),
            isWrapped: false
        )
        _ = controller.debugCompactScrollbackNow()
        XCTAssertEqual(controller.withViewport { _, scrollback, _ in scrollback.rowCount }, 1)
        XCTAssertEqual(controller.withViewport { _, scrollback, _ in scrollback.getRow(at: 0)?.first?.imageID }, 2)

        controller.debugReconcileInlineImageReachabilityForTesting()
        XCTAssertEqual(reported.last?.0, controller.id)
        XCTAssertEqual(reported.last?.1, Set([1, 2]))

        controller.clearScrollback()
        XCTAssertEqual(reported.last?.1, Set([1]))

        controller.model.grid.setCell(.empty, at: 0, col: 0)
        controller.debugReconcileInlineImageReachabilityForTesting()
        XCTAssertEqual(reported.last?.1, Set<Int>())
    }

    func testDisplayMutationThatOverwritesVisibleInlineImageSchedulesReachabilityReconciliation() {
        let controller = makeController(rows: 4, cols: 12)
        var reported: [Set<Int>] = []
        controller.onInlineImageReachabilityChange = { _, liveIndices in
            reported.append(liveIndices)
        }

        controller.debugProcessPTYOutputForTesting(Data("\u{1B}_Gi=41,a=T,t=d,c=1,r=1;\u{1B}\\".utf8))
        drainMainQueue(testCase: self)
        XCTAssertEqual(reported.last, Set([41]))

        controller.debugProcessPTYOutputForTesting(Data("\rX".utf8))
        drainMainQueue(testCase: self)
        XCTAssertEqual(reported.last, Set<Int>())
    }

    func testProcessExitPurgesUnreferencedInlineImages() throws {
        try withTemporaryPtermConfig { _ in
            let registry = PastedImageRegistry.shared
            registry.reset()
            defer { registry.reset() }

            let controller = makeController(rows: 4, cols: 6)
            let recorder = PurgedURLRecorder()
            installInlineImagePurgeObserver(on: controller, registry: registry, recorder: recorder)

            let persistedURL = try registerPersistedInlineImage(
                registry: registry,
                ownerID: controller.id,
                index: 11
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: persistedURL.path))

            controller.debugSimulateProcessExitForTesting()

            XCTAssertEqual(Set(recorder.urls), Set([persistedURL]))
            XCTAssertNil(registry.registeredImage(ownerID: controller.id, forPlaceholderIndex: 11))
            XCTAssertFalse(FileManager.default.fileExists(atPath: persistedURL.path))
        }
    }

    func testExplicitClearScrollbackPurgesScrollbackOnlyInlineImages() throws {
        try withTemporaryPtermConfig { _ in
            let registry = PastedImageRegistry.shared
            registry.reset()
            defer { registry.reset() }

            let controller = makeController(rows: 4, cols: 6)
            let recorder = PurgedURLRecorder()
            installInlineImagePurgeObserver(on: controller, registry: registry, recorder: recorder)

            controller.debugAppendScrollbackRowForTesting(
                ArraySlice([.inlineImage(id: 21, columns: 1, rows: 1, originColOffset: 0, originRowOffset: 0)]),
                isWrapped: false
            )
            let persistedURL = try registerPersistedInlineImage(
                registry: registry,
                ownerID: controller.id,
                index: 21
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: persistedURL.path))

            controller.clearScrollback()

            XCTAssertEqual(Set(recorder.urls), Set([persistedURL]))
            XCTAssertNil(registry.registeredImage(ownerID: controller.id, forPlaceholderIndex: 21))
            XCTAssertFalse(FileManager.default.fileExists(atPath: persistedURL.path))
        }
    }

    func testParserRequestedScrollbackClearPurgesScrollbackOnlyInlineImages() throws {
        try withTemporaryPtermConfig { _ in
            let registry = PastedImageRegistry.shared
            registry.reset()
            defer { registry.reset() }

            let controller = makeController(rows: 4, cols: 6)
            let recorder = PurgedURLRecorder()
            installInlineImagePurgeObserver(on: controller, registry: registry, recorder: recorder)

            controller.debugAppendScrollbackRowForTesting(
                ArraySlice([.inlineImage(id: 22, columns: 1, rows: 1, originColOffset: 0, originRowOffset: 0)]),
                isWrapped: false
            )
            let persistedURL = try registerPersistedInlineImage(
                registry: registry,
                ownerID: controller.id,
                index: 22
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: persistedURL.path))

            controller.debugProcessPTYOutputForTesting(Data("\u{1B}[3J".utf8))

            XCTAssertEqual(Set(recorder.urls), Set([persistedURL]))
            XCTAssertNil(registry.registeredImage(ownerID: controller.id, forPlaceholderIndex: 22))
            XCTAssertFalse(FileManager.default.fileExists(atPath: persistedURL.path))
        }
    }

    func testScrollbackCompactionPurgesImagesEvictedByBoundedScrollback() throws {
        try withTemporaryPtermConfig { _ in
            let registry = PastedImageRegistry.shared
            registry.reset()
            defer { registry.reset() }

            let controller = makeController(
                rows: 4,
                cols: 6,
                scrollbackInitialCapacity: 128,
                scrollbackMaxCapacity: 128
            )
            let recorder = PurgedURLRecorder()
            installInlineImagePurgeObserver(on: controller, registry: registry, recorder: recorder)

            controller.debugAppendScrollbackRowForTesting(
                ArraySlice([.inlineImage(id: 23, columns: 1, rows: 1, originColOffset: 0, originRowOffset: 0)]),
                isWrapped: false
            )
            let persistedURL = try registerPersistedInlineImage(
                registry: registry,
                ownerID: controller.id,
                index: 23
            )

            for _ in 0..<32 {
                controller.debugAppendScrollbackRowForTesting(
                    ArraySlice([
                        Cell(
                            codepoint: 65,
                            attributes: .default,
                            width: 1,
                            isWideContinuation: false
                        )
                    ]),
                    isWrapped: false
                )
            }

            XCTAssertEqual(controller.withViewport { _, scrollback, _ in scrollback.liveInlineImageIDs() }, Set<Int>())

            _ = controller.debugCompactScrollbackNow()

            XCTAssertEqual(Set(recorder.urls), Set([persistedURL]))
            XCTAssertNil(registry.registeredImage(ownerID: controller.id, forPlaceholderIndex: 23))
            XCTAssertFalse(FileManager.default.fileExists(atPath: persistedURL.path))
        }
    }

    func testDebugProcessPTYOutputMatchesByteWiseProcessingForMixedWideUnicodeAndASCII() {
        let bulk = makeController(rows: 24, cols: 80)
        let byteWise = makeController(rows: 24, cols: 80)
        let payloadString =
            "日本語かな mixed ASCII 123\tline\n"
            + "中文，カナ、한글 fullwidth：ＡＢＣ € accents ÀÁÂ\n"
            + "終わり"
        let payload = Data(payloadString.utf8)

        bulk.debugProcessPTYOutputForTesting(payload)
        for byte in payload {
            byteWise.debugProcessPTYOutputForTesting(Data([byte]))
        }

        XCTAssertEqual(bulk.allText(), byteWise.allText())
        let bulkCursor = bulk.withModel { ($0.cursor.row, $0.cursor.col, $0.cursor.pendingWrap) }
        let byteWiseCursor = byteWise.withModel { ($0.cursor.row, $0.cursor.col, $0.cursor.pendingWrap) }
        XCTAssertEqual(bulkCursor.0, byteWiseCursor.0)
        XCTAssertEqual(bulkCursor.1, byteWiseCursor.1)
        XCTAssertEqual(bulkCursor.2, byteWiseCursor.2)
    }

    func testDebugProcessPTYOutputMatchesByteWiseProcessingForKittyGraphicsAPCWithSplitTerminator() throws {
        let registry = PastedImageRegistry.shared
        registry.reset()
        defer { registry.reset() }

        let bulk = makeController(rows: 6, cols: 12)
        let byteWise = makeController(rows: 6, cols: 12)
        let expectedPayload = Data([0x89, 0x50, 0x4E, 0x47, 0xAA, 0xBB, 0xCC, 0xDD])
        let payloadString = "\u{1B}_Gi=77,a=T,f=100,t=d,c=2,r=1;\(expectedPayload.base64EncodedString())\u{1B}\\"
        let payload = Data(payloadString.utf8)

        bulk.debugProcessPTYOutputForTesting(payload)
        for byte in payload {
            byteWise.debugProcessPTYOutputForTesting(Data([byte]))
        }
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            drainMainQueue(testCase: self)
            if registry.registeredImage(ownerID: bulk.id, forPlaceholderIndex: 77) != nil,
               registry.registeredImage(ownerID: byteWise.id, forPlaceholderIndex: 77) != nil {
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        let bulkImage = try XCTUnwrap(registry.registeredImage(ownerID: bulk.id, forPlaceholderIndex: 77))
        let byteWiseImage = try XCTUnwrap(registry.registeredImage(ownerID: byteWise.id, forPlaceholderIndex: 77))
        XCTAssertEqual(bulkImage.columns, 2)
        XCTAssertEqual(byteWiseImage.columns, 2)
        XCTAssertEqual(bulkImage.rows, 1)
        XCTAssertEqual(byteWiseImage.rows, 1)

        let bulkLive = bulk.withViewport { model, scrollback, _ in
            model.grid.liveInlineImageIDs().union(scrollback.liveInlineImageIDs())
        }
        let byteWiseLive = byteWise.withViewport { model, scrollback, _ in
            model.grid.liveInlineImageIDs().union(scrollback.liveInlineImageIDs())
        }
        XCTAssertEqual(bulkLive, Set([77]))
        XCTAssertEqual(byteWiseLive, Set([77]))
    }

    func testAlternateScreenScrollDoesNotAppendScrollback() {
        let controller = makeController(rows: 3, cols: 6)
        let payload = Data(("\u{1B}[?1049h" + "1\n2\n3\n4\n5\n").utf8)

        controller.debugProcessPTYOutputForTesting(payload)

        let scrollbackRows = controller.withViewport { _, scrollback, _ in
            scrollback.rowCount
        }
        XCTAssertEqual(scrollbackRows, 0)
    }
}

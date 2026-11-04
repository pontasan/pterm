import XCTest
import AppKit
@testable import PtermApp

/// Runs a real full-screen application in a real terminal: a real AppDelegate, a real PTY and
/// events through the real entry points, which is what a recording cannot do for behavior that
/// depends on how the application answers pterm. The application's text may be private, so this
/// runs only on request: set PTERM_TEST_LIVE_TUI_COMMAND to the command line and
/// PTERM_TEST_LIVE_TUI_DIRECTORY to where to run it. The clipboard of the machine stays out of it:
/// pterm gets a private pasteboard, and the application a pbcopy that writes to a temporary file.
final class LiveApplicationSelectionTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Without mouse tracking a wheel event goes to AppKit, which then waits for the rest of the
    /// gesture from the real input device, forever. Fail with what is on the screen instead.
    private func requireMouseTracking(_ controller: TerminalController) -> Bool {
        let (tracking, screen) = controller.withModel { model -> (Bool, String) in
            (model.mouseReporting != .none, (0..<model.rows).map { row in
                (0..<model.cols).map { model.grid.cell(at: row, col: $0) }
                    .filter { !$0.isWideContinuation }
                    .map { $0.renderedString() }.joined()
            }.joined(separator: "\n"))
        }
        XCTAssertTrue(tracking, "The application stopped tracking the mouse. Screen:\n\(screen)")
        return tracking
    }

    private func allViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }

    func testSelectionsSurviveFlingAndCopyInARealApplication() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let command = environment["PTERM_TEST_LIVE_TUI_COMMAND"],
              let directory = environment["PTERM_TEST_LIVE_TUI_DIRECTORY"] else {
            throw XCTSkip("No application provided")
        }
        guard let renderer = MetalRenderer(scaleFactor: 2.0) else { throw XCTSkip("Metal unavailable") }
        let privatePasteboard = NSPasteboard(name: NSPasteboard.Name("pterm.test.\(UUID().uuidString)"))
        let machinePasteboardChanges = NSPasteboard.general.changeCount
        let tools = FileManager.default.temporaryDirectory.appendingPathComponent("pterm-live-\(UUID().uuidString)")
        let applicationCopy = tools.appendingPathComponent("copied")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer {
            privatePasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: tools)
        }
        let fakeCopyTool = tools.appendingPathComponent("pbcopy")
        try "#!/bin/sh\ncat > '\(applicationCopy.path)'\n".write(to: fakeCopyTool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCopyTool.path)

        let manager = TerminalManager(rows: 40, cols: 120, config: .default)
        defer { manager.stopAll(waitForExit: false) }
        let controller = try manager.addTerminal(initialDirectory: directory, workspaceName: "Live", fontName: "Menlo", fontSize: 13)
        let delegate = AppDelegate()
        delegate.terminalPasteboard = privatePasteboard
        NSApplication.shared.delegate = delegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: window.frame)
        root.wantsLayer = true
        window.contentView = root
        let hosted = NSView(frame: root.bounds)
        hosted.autoresizingMask = [.width, .height]
        root.addSubview(hosted)
        delegate.configureForTesting(window: window, renderer: renderer, manager: manager, hostedContentView: hosted)
        window.makeKeyAndOrderFront(nil)
        delegate.switchToSplit([controller])
        spin(1)
        let view = try XCTUnwrap(allViews(hosted).compactMap { $0 as? TerminalView }.first)
        window.makeFirstResponder(view)
        spin(2)
        controller.sendInput("PATH='\(tools.path)':\"$PATH\" " + command + "\r")
        spin(12)
        XCTAssertTrue(controller.applicationOwnsScrolling, "The application must be running with mouse tracking.")
        let (rowCount, colCount) = controller.withModel { ($0.rows, $0.cols) }
        let cellWidth = renderer.glyphAtlas.cellWidth
        let cellHeight = renderer.glyphAtlas.cellHeight
        let padding = renderer.gridPadding

        func point(_ row: Int, _ col: Int) -> NSPoint {
            NSPoint(x: padding + CGFloat(col) * cellWidth + cellWidth / 2,
                    y: view.bounds.height - padding - CGFloat(row) * cellHeight - cellHeight / 2)
        }
        func mouse(_ type: NSEvent.EventType, _ row: Int, _ col: Int, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point(row, col), to: nil), modifierFlags: modifiers,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func click(_ row: Int, _ col: Int, _ modifiers: NSEvent.ModifierFlags = []) {
            view.mouseDown(with: mouse(.leftMouseDown, row, col, modifiers))
            view.mouseUp(with: mouse(.leftMouseUp, row, col, modifiers))
        }
        func wheel(_ deltaY: Int32, phase: Int64 = 2) {
            guard requireMouseTracking(controller) else { return }
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0)!
            // A synthesized event takes on the keys held on the real keyboard, and Option sends
            // the wheel to AppKit, which then waits for the rest of the gesture from the device.
            event.flags = []
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.location = window.convertPoint(toScreen: view.convert(point(20, 40), to: nil))
            view.scrollWheel(with: NSEvent(cgEvent: event)!)
        }
        func screen() -> [String] {
            controller.withModel { model in
                (0..<model.rows).map { row in
                    (0..<model.cols).map { model.grid.cell(at: row, col: $0) }
                        .filter { !$0.isWideContinuation }
                        .map { $0.renderedString() }.joined()
                        .replacingOccurrences(of: " ", with: "")
                }
            }
        }
        func highlightedCells() -> Int {
            controller.withModel { model in
                var count = 0
                for row in 0..<model.rows {
                    for col in 0..<model.cols where model.grid.cell(at: row, col: col).attributes.background == .rgb(38, 79, 120) {
                        count += 1
                    }
                }
                return count
            }
        }
        // Rows naming a tool act on a click, opening what they hold. Prose does not.
        func isPlainText(_ row: String) -> Bool {
            row.count > 10 && !["(", "Ran", "Read", "Wrote", "⎿", "…", "⏺", "❯"].contains { row.contains($0) }
        }
        // Plain clicks clear selections, and must not open anything the application shows.
        func clickWhereNothingHappens() {
            let rows = screen()
            let row = rows.indices.first { $0 < rowCount - 10 && isPlainText(rows[$0]) } ?? rowCount - 7
            click(row, colCount - 1)
        }
        // A row can show the application's own hint drawn over the middle of the text.
        func isCovered(_ text: String, by row: String) -> Bool {
            let visible = row.prefix { !"Jump".hasPrefix(String($0)) }
            return row.contains("Jumptobottom") && text.hasPrefix(visible)
        }
        // The application leaves its gutter marks out of what it copies.
        func compact(_ text: String) -> String {
            text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "⏺", with: "")
        }
        func describeDifference(_ a: String, _ b: String) -> String {
            let common = a.commonPrefix(with: b).count
            return "at \(common): [\(a.dropFirst(max(common - 15, 0)).prefix(40))] vs [\(b.dropFirst(max(common - 15, 0)).prefix(40))]"
        }
        func pasteboard() -> String {
            (try? String(contentsOf: applicationCopy, encoding: .utf8)) ?? privatePasteboard.string(forType: .string) ?? ""
        }
        func clearPasteboard() {
            privatePasteboard.clearContents()
            privatePasteboard.setString("SENTINEL", forType: .string)
            try? FileManager.default.removeItem(at: applicationCopy)
        }
        let commandC = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "c",
                                        charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!

        // A fling away and back with a Shift+click selection, in both orders.
        for round in 0..<4 {
            let rows = screen()
            let candidates = rows.indices.filter { row in
                row < rowCount - 10 && isPlainText(rows[row]) && rows.filter { $0 == rows[row] }.count == 1
            }
            XCTAssertGreaterThanOrEqual(candidates.count, 2, "The application must show text.")
            guard candidates.count >= 2 else { return }
            let firstRow = candidates[candidates.count / 2 - 1]
            let lastRow = candidates[candidates.count / 2]
            click(firstRow, 0)
            spin(0.1)
            click(lastRow, colCount - 1, [.shift])
            spin(0.5)
            let firstText = rows[firstRow]
            let selectedText = compact(try XCTUnwrap(view.selectedText()))
            let base = controller.viewportRowToGlobalRow(0)
            var misplaced: [String] = []
            for direction: Int32 in round % 2 == 0 ? [1, -1] : [-1, 1] {
                wheel(0, phase: 1)
                for step in 0..<60 {
                    wheel(direction * Int32(max(3, 400 - step * 6)), phase: step == 0 ? 1 : 2)
                    spin(1.0 / 120)
                    guard controller.withModel({ $0.cursor.visible }) else { continue }
                    let selection = try XCTUnwrap(view.selection, "round \(round) step \(step)")
                    let painted = selection.start.row - base
                    let current = screen()
                    if current.indices.contains(painted), current[painted] == firstText {
                        continue
                    }
                    // The first frames showing a pinned first row cannot be told from text yet.
                    if painted == 0, current[0].hasPrefix("❯") {
                        continue
                    }
                    if let actual = current.firstIndex(of: firstText) {
                        // Off the screen above, a prompt can stay in sight as a pinned first row.
                        if actual != painted, !(actual == 0 && painted < 0) {
                            misplaced.append("\(round)/\(step): painted \(painted), text \(actual)")
                        }
                    } else if current.indices.contains(painted), selection.isPaintable(viewportRow: painted),
                              !isCovered(firstText, by: current[painted]) {
                        misplaced.append("\(round)/\(step): painted \(painted), text off the screen")
                    }
                }
                wheel(0, phase: 4)
                spin(0.6)
            }
            XCTAssertTrue(misplaced.isEmpty, "\(misplaced.prefix(5))")
            let finalText = compact(view.selectedText() ?? "")
            XCTAssertTrue(finalText == selectedText, "round \(round) rows \(firstRow)...\(lastRow) " + describeDifference(finalText, selectedText)
                          + " selection \(String(describing: view.selection)) state \(controller.appScrollSelectionState())")
            XCTAssertTrue(window.performKeyEquivalent(with: commandC))
            spin(0.3)
            XCTAssertNotNil(view.selection, "Copying keeps pterm's selection.")
            XCTAssertEqual(compact(privatePasteboard.string(forType: .string) ?? ""), selectedText, "round \(round)")
            clickWhereNothingHappens()
            spin(0.3)
            XCTAssertNil(view.selection, "A plain click clears it.")
        }

        // What the application selects itself: a drag, a double and a triple click.
        let dragRow = try XCTUnwrap(screen().indices.first { $0 < rowCount - 12 && isPlainText(screen()[$0]) })
        clearPasteboard()
        view.mouseDown(with: mouse(.leftMouseDown, dragRow, 2))
        spin(0.05)
        view.mouseDragged(with: mouse(.leftMouseDragged, dragRow + 3, 30))
        spin(0.05)
        view.mouseUp(with: mouse(.leftMouseUp, dragRow + 3, 30))
        spin(1)
        let dragHighlight = highlightedCells()
        let applicationsOwnCopy = pasteboard()
        XCTAssertGreaterThan(dragHighlight, 0)
        XCTAssertTrue(window.performKeyEquivalent(with: commandC))
        spin(0.6)
        XCTAssertEqual(highlightedCells(), dragHighlight, "Copying must leave the application's highlight alone.")
        let draggedText = compact(view.selectedText() ?? "")
        XCTAssertEqual(compact(privatePasteboard.string(forType: .string) ?? ""), draggedText, "What Cmd+C put on the clipboard.")
        XCTAssertTrue(draggedText == compact(applicationsOwnCopy), describeDifference(draggedText, compact(applicationsOwnCopy)))

        // Some rows act on a click instead, so any row that highlights will do.
        for clicks in [2, 3] {
            var answered = false
            let rows = screen()
            for textRow in rows.indices where !answered && isPlainText(rows[textRow]) && textRow > 3 && textRow < rowCount - 10 {
                clickWhereNothingHappens()
                spin(0.5)
                clearPasteboard()
                for _ in 0..<clicks {
                    click(textRow, 4)
                    spin(0.03)
                }
                spin(1)
                let highlight = highlightedCells()
                guard highlight > 0 else { continue }
                answered = true
                let own = pasteboard()
                // Without its own copy, the application took this for something else than a selection.
                guard own != "SENTINEL" else { continue }
                XCTAssertTrue(window.performKeyEquivalent(with: commandC))
                spin(0.5)
                XCTAssertEqual(highlightedCells(), highlight, "\(clicks) clicks")
                let text = compact(view.selectedText() ?? "")
                XCTAssertEqual(compact(privatePasteboard.string(forType: .string) ?? ""), text, "\(clicks) clicks")
                XCTAssertTrue(text == compact(own), "\(clicks) clicks " + describeDifference(text, compact(own)))
            }
            if !rows.indices.filter({ isPlainText(rows[$0]) && $0 > 3 && $0 < rowCount - 10 }).isEmpty {
                XCTAssertTrue(answered, "\(clicks) clicks highlighted nothing")
            }
        }

        // With nothing selected, the key remains the interrupt it always was.
        clickWhereNothingHappens()
        spin(0.5)
        clearPasteboard()
        XCTAssertTrue(window.performKeyEquivalent(with: commandC))
        spin(0.3)
        XCTAssertEqual(pasteboard(), "SENTINEL")
        controller.sendInput("\u{3}\u{3}")
        spin(1)
        print("LIVE machine pasteboard changes during the test: \(NSPasteboard.general.changeCount - machinePasteboardChanges)")
    }

    /// The same fling and copy against any application that scrolls a file by the wheel. Set
    /// PTERM_TEST_LIVE_SCROLL_COMMAND to a command line where {FILE} stands for a generated file
    /// of unique lines. Nothing of the user's is shown, and the machine's clipboard is untouched.
    func testSelectionFollowsAGeneratedFileInARealApplication() throws {
        guard let template = ProcessInfo.processInfo.environment["PTERM_TEST_LIVE_SCROLL_COMMAND"] else {
            throw XCTSkip("No application provided")
        }
        guard let renderer = MetalRenderer(scaleFactor: 2.0) else { throw XCTSkip("Metal unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pterm-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("lines.txt")
        try (1...5000).map { "line-\($0)-\(String($0 &* 2654435761, radix: 36))" }.joined(separator: "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let manager = TerminalManager(rows: 40, cols: 120, config: .default)
        defer { manager.stopAll(waitForExit: false) }
        let controller = try manager.addTerminal(initialDirectory: directory.path, workspaceName: "Live", fontName: "Menlo", fontSize: 13)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        spin(2)
        controller.sendInput(template.replacingOccurrences(of: "{FILE}", with: file.path) + "\r")
        spin(3)
        XCTAssertTrue(controller.applicationOwnsScrolling, "The application must be running with mouse tracking.")
        let colCount = controller.withModel { $0.cols }
        let cellWidth = renderer.glyphAtlas.cellWidth
        let cellHeight = renderer.glyphAtlas.cellHeight
        let padding = renderer.gridPadding

        func point(_ row: Int, _ col: Int) -> NSPoint {
            NSPoint(x: padding + CGFloat(col) * cellWidth + cellWidth / 2,
                    y: view.bounds.height - padding - CGFloat(row) * cellHeight - cellHeight / 2)
        }
        func click(_ row: Int, _ col: Int, _ modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: view.convert(point(row, col), to: nil), modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
            }
        }
        func wheel(_ deltaY: Int32, phase: Int64 = 2) {
            guard requireMouseTracking(controller) else { return }
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0)!
            // A synthesized event takes on the keys held on the real keyboard, and Option sends
            // the wheel to AppKit, which then waits for the rest of the gesture from the device.
            event.flags = []
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.location = window.convertPoint(toScreen: view.convert(point(20, 40), to: nil))
            view.scrollWheel(with: NSEvent(cgEvent: event)!)
        }
        func screen() -> [String] {
            controller.withModel { model in
                (0..<model.rows).map { row in
                    (0..<model.cols).map { model.grid.cell(at: row, col: $0) }
                        .filter { !$0.isWideContinuation }
                        .map { $0.renderedString() }.joined()
                }
            }
        }
        // Over a slow link the screen keeps moving well after the last event.
        func waitUntilScreenStops() {
            var last = screen()
            var stillSince = Date()
            let deadline = Date().addingTimeInterval(15)
            while Date().timeIntervalSince(stillSince) < 1, Date() < deadline {
                spin(0.05)
                let current = screen()
                if current != last {
                    last = current
                    stillSince = Date()
                }
            }
        }
        func lineName(_ row: String) -> String? {
            guard let range = row.range(of: "line-[0-9]+-[0-9a-z]+", options: .regularExpression) else { return nil }
            return String(row[range])
        }

        // Scroll away from the start of the file, so that both directions can move.
        for _ in 0..<3 { wheel(-1200); spin(0.3) }
        var rows = screen()
        var named = rows.indices.filter { lineName(rows[$0]) != nil }
        XCTAssertGreaterThan(named.count, 10, "The application must show the file: \(rows.prefix(3))")
        guard named.count > 10 else { return }
        var moves = 0
        var failures: [String] = []
        for round in 0..<6 {
            waitUntilScreenStops()
            rows = screen()
            named = rows.indices.filter { lineName(rows[$0]) != nil }
            guard named.count > 10 else { failures.append("round \(round): file not showing"); break }
            let firstRow = named[named.count / 3]
            let lastRow = named[named.count / 3 + 2]
            let firstName = try XCTUnwrap(lineName(rows[firstRow]))
            let middleName = try XCTUnwrap(lineName(rows[firstRow + 1]))
            let lastName = try XCTUnwrap(lineName(rows[lastRow]))
            view.clearSelection()
            click(firstRow, 0)
            spin(0.1)
            click(lastRow, colCount - 1, [.shift])
            waitUntilScreenStops()
            let shiftAtStart = controller.appScrollSelectionState().globalShift
            for (direction, speed) in [(Int32(round % 2 == 0 ? 1 : -1), Int32(300)), (Int32(round % 2 == 0 ? -1 : 1), Int32(100))] {
                wheel(0, phase: 1)
                for step in 0..<30 {
                    wheel(direction * max(3, speed - Int32(step) * 3), phase: step == 0 ? 1 : 2)
                    spin(1.0 / 120)
                }
                wheel(0, phase: 4)
                waitUntilScreenStops()
                guard let selection = view.selection else {
                    failures.append("round \(round): selection lost")
                    break
                }
                let current = screen()
                let base = controller.viewportRowToGlobalRow(0)
                let painted = selection.start.row - base
                if let actual = current.firstIndex(where: { lineName($0) == firstName }) {
                    if actual != painted { failures.append("round \(round): painted \(painted), text \(actual)") }
                } else if current.indices.contains(painted), selection.isPaintable(viewportRow: painted) {
                    failures.append("round \(round): painted \(painted), text off the screen")
                }
            }
            moves += abs(controller.appScrollSelectionState().globalShift - shiftAtStart)
            guard view.selection != nil else { continue }
            let copied = (view.selectedText() ?? "").components(separatedBy: "\n").compactMap(lineName)
            if copied != [firstName, middleName, lastName] {
                failures.append("round \(round): copied \(copied.prefix(5)), expected \([firstName, middleName, lastName]): \((view.selectedText() ?? "").prefix(120))")
            }
        }
        print("LIVE-SCROLL \(template.prefix(30)) moved \(moves) failures \(failures.count)")
        XCTAssertGreaterThan(moves, 0, "The application must actually scroll.")
        XCTAssertTrue(failures.isEmpty, "\(failures.prefix(6))")
    }

    /// Scrolling while a real application is writing. PTERM_TEST_LIVE_STREAM_COMMAND starts it,
    /// PTERM_TEST_LIVE_STREAM_DIRECTORY is where, and PTERM_TEST_LIVE_STREAM_INPUT is typed into it,
    /// which must make it print lines holding only a number, counting up, slowly.
    func testSelectionFollowsTextWhileARealApplicationWrites() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let command = environment["PTERM_TEST_LIVE_STREAM_COMMAND"],
              let directory = environment["PTERM_TEST_LIVE_STREAM_DIRECTORY"],
              let input = environment["PTERM_TEST_LIVE_STREAM_INPUT"] else {
            throw XCTSkip("No application provided")
        }
        guard let renderer = MetalRenderer(scaleFactor: 2.0) else { throw XCTSkip("Metal unavailable") }
        let manager = TerminalManager(rows: 40, cols: 120, config: .default)
        defer { manager.stopAll(waitForExit: false) }
        let controller = try manager.addTerminal(initialDirectory: directory, workspaceName: "Live", fontName: "Menlo", fontSize: 13)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        spin(2)
        controller.sendInput(command + "\r")
        spin(8)
        controller.sendInput(input)
        spin(0.5)
        controller.sendInput("\r")
        let cellWidth = renderer.glyphAtlas.cellWidth
        let cellHeight = renderer.glyphAtlas.cellHeight
        let padding = renderer.gridPadding
        func point(_ row: Int, _ col: Int) -> NSPoint {
            NSPoint(x: padding + CGFloat(col) * cellWidth + cellWidth / 2,
                    y: view.bounds.height - padding - CGFloat(row) * cellHeight - cellHeight / 2)
        }
        func click(_ row: Int, _ col: Int, _ modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: view.convert(point(row, col), to: nil), modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
            }
        }
        func wheel(_ deltaY: Int32, phase: Int64 = 2) {
            guard requireMouseTracking(controller) else { return }
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0)!
            // A synthesized event takes on the keys held on the real keyboard, and Option sends
            // the wheel to AppKit, which then waits for the rest of the gesture from the device.
            event.flags = []
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.location = window.convertPoint(toScreen: view.convert(point(20, 40), to: nil))
            view.scrollWheel(with: NSEvent(cgEvent: event)!)
        }
        func screen() -> [String] {
            controller.withModel { model in
                (0..<model.rows).map { row in
                    (0..<model.cols).map { model.grid.cell(at: row, col: $0) }
                        .filter { !$0.isWideContinuation }
                        .map { $0.renderedString() }.joined()
                }
            }
        }
        func number(_ row: String) -> Int? {
            let text = row.replacingOccurrences(of: "⏺", with: "").trimmingCharacters(in: .whitespaces)
            return text.count <= 6 ? Int(text) : nil
        }
        // Wait for the numbers to start filling the screen.
        var rows = screen()
        var numbered = rows.indices.filter { number(rows[$0]) != nil }
        let deadline = Date().addingTimeInterval(60)
        while numbered.count < 12, Date() < deadline {
            spin(0.05)
            rows = screen()
            numbered = rows.indices.filter { number(rows[$0]) != nil }
        }
        XCTAssertGreaterThanOrEqual(numbered.count, 12, "No numbers appeared: \(rows.suffix(8))")
        guard numbered.count >= 12 else { return }

        let firstRow = numbered[numbered.count / 2]
        let lastRow = numbered[numbered.count / 2 + 2]
        let firstNumber = number(rows[firstRow])!
        let lastNumber = number(rows[lastRow])!
        click(firstRow, 0)
        spin(0.03)
        click(lastRow, 20, [.shift])
        let base = controller.viewportRowToGlobalRow(0)
        var checks = 0
        var hidden = 0
        var maxNumber = 0
        var failures: [String] = []
        func check(_ tag: String) {
            guard controller.withModel({ $0.cursor.visible }) else { return }
            guard let selection = view.selection else {
                failures.append("\(tag): selection lost")
                return
            }
            let current = screen()
            maxNumber = max(maxNumber, current.compactMap(number).max() ?? 0)
            let painted = selection.start.row - base
            checks += 1
            if let actual = current.firstIndex(where: { number($0) == firstNumber }) {
                if actual != painted { failures.append("\(tag): painted \(painted), text \(actual)") }
            } else {
                hidden += 1
                if current.indices.contains(painted), selection.isPaintable(viewportRow: painted) {
                    failures.append("\(tag): painted \(painted), text off the screen")
                }
            }
        }
        // Stay put while lines arrive, then scroll both ways while they keep arriving.
        for step in 0..<60 {
            spin(0.05)
            check("wait \(step)")
        }
        let copiedWhileWriting = view.selectedText() ?? ""
        for round in 0..<6 {
            let direction: Int32 = round % 2 == 0 ? 1 : -1
            wheel(0, phase: 1)
            for step in 0..<30 {
                wheel(direction * 60, phase: step == 0 ? 1 : 2)
                spin(1.0 / 60)
                check("\(round)/\(step)")
            }
            wheel(0, phase: 4)
            spin(0.2)
            check("\(round) end")
        }
        let copied = (view.selectedText() ?? "").components(separatedBy: "\n").compactMap(number)
        print("LIVE-STREAM checks \(checks) hidden \(hidden) largest number \(maxNumber) selected \(firstNumber)...\(lastNumber) failures \(failures.count) copied \(copied) whileWriting \(copiedWhileWriting.prefix(30).debugDescription)")
        XCTAssertEqual(copied, Array(firstNumber...lastNumber))
        XCTAssertGreaterThan(maxNumber, lastNumber + 10, "Lines must have kept arriving.")
        XCTAssertTrue(failures.isEmpty, "\(failures.prefix(6))")
        controller.sendInput("\u{3}\u{3}")
        spin(1)
    }
}

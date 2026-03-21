import XCTest
@testable import PtermApp

final class TerminalManagerIntegrationTests: XCTestCase {
    func testTerminalManagerAddTerminalAppliesConfiguredScrollbackBudgetAndEncoding() throws {
        let config = PtermConfig(
            term: "xterm-256color",
            textEncoding: .utf16,
            shellLaunch: .default,
            textInteraction: .default,
            fontName: nil,
            fontSize: nil,
            terminalAppearance: .default,
            memoryMax: 2 * 1024 * 1024,
            memoryInitial: 1024 * 1024,
            sessionScrollBufferPersistence: false,
            audit: .disabled,
            security: .default,
            mcpServer: .default,
            ai: .default,
            shortcuts: .default,
            workspaces: []
        )
        let manager = TerminalManager(rows: 24, cols: 80, config: config)
        defer { manager.stopAll(waitForExit: true) }

        let controller = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            fontName: "Menlo",
            fontSize: 13
        )

        XCTAssertEqual(controller.scrollbackCapacity, UInt64(1024 * 1024))
        XCTAssertEqual(controller.sessionSnapshot.settings?.textEncoding, TerminalTextEncoding.utf16.rawValue)
        XCTAssertEqual(manager.count, 1)
    }

    func testTerminalManagerUpdateFullSizeResizesExistingControllers() throws {
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }

        let controller = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            fontName: "Menlo",
            fontSize: 13
        )

        manager.updateFullSize(rows: 40, cols: 120)

        let size = controller.withModel { ($0.rows, $0.cols) }
        XCTAssertEqual(size.0, 40)
        XCTAssertEqual(size.1, 120)
    }
}

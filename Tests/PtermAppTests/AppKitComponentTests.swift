import AppKit
import Metal
import MetalKit
import ObjectiveC.runtime
import QuartzCore
import XCTest
@testable import PtermApp

@MainActor
final class AppKitComponentTests: XCTestCase {
    private static func projectRootURL(filePath: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

    func testStatusBarViewShowsNoteButtonAndFormatsMetrics() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        view.updateCpuUsage(percent: 12.4)
        view.updateMemoryUsage(bytes: 512 * 1024 * 1024)
        view.layoutSubtreeIfNeeded()

        let labels = view.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(labels.contains("CPU: 12.4% | MEM: 512MB"))

        let buttonTitles = view.subviews.compactMap { $0 as? NSButton }.map(\.title)
        XCTAssertTrue(buttonTitles.contains("Edit Notes"))
        XCTAssertTrue(buttonTitles.contains("◀ Overview"))
    }

    func testStatusBarViewStartsWithPlaceholderMetrics() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        view.layoutSubtreeIfNeeded()

        let labels = allSubviews(in: view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(labels.contains("CPU: --.-% | MEM: -- MB"))
    }

    func testStatusBarButtonsInvokeCallbacks() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        var didBack = false
        var didOpenNote = false
        view.onBackToIntegrated = { didBack = true }
        view.onOpenNote = { didOpenNote = true }
        view.setBackButtonVisible(true)
        view.layoutSubtreeIfNeeded()

        let buttons = view.subviews.compactMap { $0 as? NSButton }
        buttons.first(where: { $0.title == "◀ Overview" })?.performClick(nil)
        buttons.first(where: { $0.title == "Edit Notes" })?.performClick(nil)

        XCTAssertTrue(didBack)
        XCTAssertTrue(didOpenNote)
    }

    func testStatusBarBackButtonVisibilityTogglesOverviewControls() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        let labels = view.subviews.compactMap { $0 as? NSTextField }
        let separator = labels.first(where: { $0.stringValue == "|" })
        let overview = view.subviews.compactMap { $0 as? NSButton }.first(where: { $0.title == "◀ Overview" })

        XCTAssertEqual(overview?.isHidden, true)
        XCTAssertEqual(separator?.isHidden, true)

        view.setBackButtonVisible(true)
        XCTAssertEqual(overview?.isHidden, false)
        XCTAssertEqual(separator?.isHidden, false)
    }

    func testStatusBarBackButtonCanBeHiddenAgainAfterShowing() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        let labels = allSubviews(in: view).compactMap { $0 as? NSTextField }
        let separator = labels.first(where: { $0.stringValue == "|" })
        let overview = allSubviews(in: view).compactMap { $0 as? NSButton }.first(where: { $0.title == "◀ Overview" })

        view.setBackButtonVisible(true)
        view.setBackButtonVisible(false)

        XCTAssertEqual(overview?.isHidden, true)
        XCTAssertEqual(separator?.isHidden, true)
    }

    func testStatusBarOverviewControlsStartHidden() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        let buttons = allSubviews(in: view).compactMap { $0 as? NSButton }
        let labels = allSubviews(in: view).compactMap { $0 as? NSTextField }

        XCTAssertEqual(buttons.first(where: { $0.title == "◀ Overview" })?.isHidden, true)
        XCTAssertEqual(labels.first(where: { $0.stringValue == "|" })?.isHidden, true)
    }

    func testStatusBarCanSwitchToTranslucentBackground() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))

        view.setTranslucentBackground(true)

        XCTAssertEqual(view.layer?.backgroundColor, NSColor.clear.cgColor)
    }

    func testStatusBarCanSwitchBackToSolidBackground() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        let expected = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor

        view.setTranslucentBackground(true)
        view.setTranslucentBackground(false)

        XCTAssertEqual(view.layer?.backgroundColor, expected)
    }

    func testSettingsWindowControllerBuildsExpectedWindowShell() throws {
        try withIsolatedSettingsController { controller in
            let window = controller.window

            XCTAssertEqual(window?.title, "Settings")
            XCTAssertEqual(window?.minSize.width, 540)
            XCTAssertEqual(window?.minSize.height, 400)
        }
    }

    func testAboutWindowControllerBuildsExpectedWindowShell() {
        let controller = AboutWindowController()
        let window = controller.window

        XCTAssertEqual(window?.title, "About pterm")
        XCTAssertEqual(window?.isReleasedWhenClosed, false)
        XCTAssertTrue(window?.styleMask.contains(.titled) ?? false)
        XCTAssertTrue(window?.styleMask.contains(.closable) ?? false)
        XCTAssertTrue(window?.styleMask.contains(.miniaturizable) ?? false)
        XCTAssertFalse(window?.styleMask.contains(.resizable) ?? true)
    }

    func testAboutWindowControllerUsesDarkAppearanceAndTransparentBackground() {
        let controller = AboutWindowController()
        let window = controller.window
        guard let background = window?.backgroundColor.usingColorSpace(.deviceRGB) else {
            XCTFail("About window background color missing")
            return
        }

        XCTAssertEqual(window?.appearance?.name, .darkAqua)
        XCTAssertFalse(window?.isOpaque ?? true)
        XCTAssertEqual(Double(background.alphaComponent), 0.0, accuracy: 0.0001)
    }

    func testAboutWindowControllerInstallsGlassBackgroundWhenAvailable() {
        let controller = AboutWindowController()

        if #available(macOS 26.0, *) {
            XCTAssertNotNil(findSubview(in: controller.window?.contentView) { $0 is NSGlassEffectView })
        }
    }

    func testAboutWindowControllerShowsApplicationMetadata() {
        let controller = AboutWindowController()
        let labels = allSubviews(in: controller.window?.contentView).compactMap { $0 as? NSTextField }.map(\.stringValue)

        XCTAssertTrue(labels.contains("pterm"))
        XCTAssertTrue(labels.contains { $0.hasPrefix("Version") })
    }

    func testWindowMaterialPolicyAlwaysUsesTranslucencyForIntegratedView() {
        XCTAssertTrue(AppDelegate.shouldUseTranslucentWindowMaterial(isIntegratedViewVisible: true, terminalBackgroundOpacity: 1.0))
        XCTAssertTrue(AppDelegate.shouldUseTranslucentWindowMaterial(isIntegratedViewVisible: true, terminalBackgroundOpacity: 0.0))
    }

    func testWindowMaterialPolicyDisablesTranslucencyOnlyForOpaqueNonIntegratedViews() {
        XCTAssertFalse(AppDelegate.shouldUseTranslucentWindowMaterial(isIntegratedViewVisible: false, terminalBackgroundOpacity: 1.0))
        XCTAssertFalse(AppDelegate.shouldUseTranslucentWindowMaterial(isIntegratedViewVisible: false, terminalBackgroundOpacity: 0.999))
    }

    func testWindowMaterialPolicyKeepsTranslucencyForTransparentFocusedTerminalBackgrounds() {
        XCTAssertTrue(AppDelegate.shouldUseTranslucentWindowMaterial(isIntegratedViewVisible: false, terminalBackgroundOpacity: 0.5))
        XCTAssertTrue(AppDelegate.shouldUseTranslucentWindowMaterial(isIntegratedViewVisible: false, terminalBackgroundOpacity: 0.0))
    }

    func testSettingsWindowControllerUsesDarkAppearanceAndSpecifiedInitialSize() throws {
        try withIsolatedSettingsController { controller in
            let window = controller.window
            let contentRect = window.map { $0.contentRect(forFrameRect: $0.frame) }

            XCTAssertEqual(window?.appearance?.name, .darkAqua)
            XCTAssertEqual(window?.isReleasedWhenClosed, false)
            XCTAssertEqual(Double(contentRect?.size.width ?? 0), 640, accuracy: 0.5)
            XCTAssertEqual(Double(contentRect?.size.height ?? 0), 480, accuracy: 0.5)
        }
    }

    func testSettingsWindowControllerSupportsExpectedWindowControls() throws {
        try withIsolatedSettingsController { controller in
            let styleMask = controller.window?.styleMask ?? []

            XCTAssertTrue(styleMask.contains(.titled))
            XCTAssertTrue(styleMask.contains(.closable))
            XCTAssertTrue(styleMask.contains(.resizable))
            XCTAssertTrue(styleMask.contains(.miniaturizable))
        }
    }

    func testSettingsWindowControllerInvokesOnCloseCallback() throws {
        try withIsolatedSettingsController { controller in
            var didClose = false
            controller.onClose = { didClose = true }

            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

            XCTAssertTrue(didClose)
        }
    }

    func testSettingsWindowSidebarListsSpecSectionsInOrder() throws {
        try withIsolatedSettingsController { controller in
            let tableView = try XCTUnwrap(findSubview(in: controller.window?.contentView) { $0 is NSTableView } as? NSTableView)

            let sectionLabels = (0..<tableView.numberOfRows).compactMap { row -> String? in
                let cell = controller.tableView(tableView, viewFor: tableView.tableColumns.first, row: row) as? NSTableCellView
                return cell?.textField?.stringValue
            }

            XCTAssertEqual(sectionLabels, ["General", "Appearance", "Memory", "Security", "Audit"])
        }
    }

    func testSettingsWindowGeneralSectionShowsExpectedPopupChoices() throws {
        try withIsolatedSettingsController { controller in
            let popups = allSubviews(in: controller.window?.contentView).compactMap { $0 as? NSPopUpButton }

            let termPopup = try XCTUnwrap(popups.first(where: { Set($0.itemTitles) == Set(["xterm-256color", "xterm", "vt100"]) }))
            let encodingPopup = try XCTUnwrap(popups.first(where: { $0.itemTitles.contains("UTF-8") && $0.itemTitles.contains("UTF-16") }))

            XCTAssertEqual(termPopup.itemTitles, ["xterm-256color", "xterm", "vt100"])
            XCTAssertEqual(encodingPopup.itemTitles, ["UTF-8", "UTF-16", "UTF-16LE", "UTF-16BE"])
        }
    }

    func testSettingsWindowGeneralSectionShowsLaunchShellListWithDefaultOrder() throws {
        try withTemporaryHomeDirectory { _ in
            PtermDirectories.ensureDirectories()
            try? FileManager.default.removeItem(at: PtermDirectories.config)
            let controller = SettingsWindowController()
            let tableView = try XCTUnwrap(
                allSubviews(in: controller.window?.contentView)
                    .compactMap { $0 as? NSTableView }
                    .first(where: { $0.identifier?.rawValue == "launchShellsTable" })
            )

            let rows = (0..<tableView.numberOfRows).compactMap { row -> String? in
                let cell = controller.tableView(tableView, viewFor: tableView.tableColumns.first, row: row) as? NSTableCellView
                return cell?.textField?.stringValue
            }
            XCTAssertEqual(rows, ShellLaunchConfiguration.default.launchOrder)
        }
    }

    func testSettingsWindowPersistsLaunchShellOrderEdits() throws {
        try withTemporaryHomeDirectory { _ in
            PtermDirectories.ensureDirectories()
            let controller = SettingsWindowController()
            let tableView = try XCTUnwrap(
                allSubviews(in: controller.window?.contentView)
                    .compactMap { $0 as? NSTableView }
                    .first(where: { $0.identifier?.rawValue == "launchShellsTable" })
            )

            let addButton = try XCTUnwrap(
                allSubviews(in: controller.window?.contentView)
                    .compactMap { $0 as? NSButton }
                    .first(where: { $0.identifier?.rawValue == "launchShellAddButton" })
            )
            addButton.performClick(nil)

            let editedField = try XCTUnwrap(
                (controller.tableView(tableView, viewFor: tableView.tableColumns.first, row: 0) as? NSTableCellView)?.textField
            )
            editedField.stringValue = "/bin/customsh"
            controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: editedField))

            let loaded = PtermConfigStore.load()
            XCTAssertEqual(loaded.shellLaunch.launchOrder, ["/bin/customsh", "/bin/bash", "/bin/sh"])
        }
    }

    func testSettingsWindowPersistsOutputConfirmedInputAnimationToggle() throws {
        try withTemporaryHomeDirectory { _ in
            PtermDirectories.ensureDirectories()
            let controller = SettingsWindowController()

            let checkbox = try XCTUnwrap(
                allSubviews(in: controller.window?.contentView)
                    .compactMap { $0 as? NSButton }
                    .first(where: { $0.title == "Output-confirm input animations" })
            )

            checkbox.state = .on
            _ = checkbox.target?.perform(checkbox.action, with: checkbox)

            let loaded = PtermConfigStore.load()
            XCTAssertTrue(loaded.textInteraction.outputConfirmedInputAnimation)
        }
    }

    func testSettingsWindowGeneralSectionShowsFactoryResetButton() throws {
        try withIsolatedSettingsController { controller in
            let buttons = allSubviews(in: controller.window?.contentView).compactMap { $0 as? NSButton }

            let resetButton = try XCTUnwrap(buttons.first(where: { $0.identifier?.rawValue == "factoryResetButton" }))

            XCTAssertEqual(resetButton.title, "Restore Defaults…")
        }
    }

    func testSettingsWindowAuditSectionStartsWithDependentControlsDisabledWhenAuditIsOff() throws {
        try withIsolatedSettingsController { controller in
            let tableView = try XCTUnwrap(findSubview(in: controller.window?.contentView) { $0 is NSTableView } as? NSTableView)

            tableView.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
            controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: tableView))

            let enableAudit = try XCTUnwrap(allSubviews(in: controller.window?.contentView).compactMap { $0 as? NSButton }.first(where: { $0.title == "Enable audit logging" }))
            let encryptLogs = try XCTUnwrap(allSubviews(in: controller.window?.contentView).compactMap { $0 as? NSButton }.first(where: { $0.title == "Encrypt audit logs" }))
            let textFields = allSubviews(in: controller.window?.contentView).compactMap { $0 as? NSTextField }
            let retentionField = try XCTUnwrap(textFields.first(where: { $0.isEditable && $0.stringValue == "30" }))

            enableAudit.state = .off
            _ = enableAudit.target?.perform(enableAudit.action, with: enableAudit)

            XCTAssertEqual(enableAudit.state, .off)
            XCTAssertFalse(retentionField.isEnabled)
            XCTAssertFalse(encryptLogs.isEnabled)
        }
    }

    func testSettingsWindowAuditSectionEnablingAuditActivatesDependentControls() throws {
        try withIsolatedSettingsController { controller in
            let tableView = try XCTUnwrap(findSubview(in: controller.window?.contentView) { $0 is NSTableView } as? NSTableView)

            tableView.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
            controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: tableView))

            let enableAudit = try XCTUnwrap(allSubviews(in: controller.window?.contentView).compactMap { $0 as? NSButton }.first(where: { $0.title == "Enable audit logging" }))
            let encryptLogs = try XCTUnwrap(allSubviews(in: controller.window?.contentView).compactMap { $0 as? NSButton }.first(where: { $0.title == "Encrypt audit logs" }))
            let textFields = allSubviews(in: controller.window?.contentView).compactMap { $0 as? NSTextField }
            let retentionField = try XCTUnwrap(textFields.first(where: { $0.isEditable && $0.stringValue == "30" }))

            enableAudit.state = .on
            _ = enableAudit.target?.perform(enableAudit.action, with: enableAudit)

            XCTAssertEqual(enableAudit.state, .on)
            XCTAssertTrue(retentionField.isEnabled)
            XCTAssertTrue(encryptLogs.isEnabled)
        }
    }

    func testSettingsWindowShowWindowPreservesSelectedSection() throws {
        try withIsolatedSettingsController { controller in
            let tableView = try XCTUnwrap(findSubview(in: controller.window?.contentView) { $0 is NSTableView } as? NSTableView)

            tableView.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
            controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: tableView))
            controller.showWindow()

            XCTAssertEqual(tableView.selectedRow, 3)
            let buttonTitles = allSubviews(in: controller.window?.contentView).compactMap { $0 as? NSButton }.map(\.title)
            XCTAssertTrue(buttonTitles.contains("Allow OSC 52 clipboard read"))
        }
    }

    func testSettingsWindowAppearanceSectionShowsTerminalColorControlsAndOpacitySlider() throws {
        try withIsolatedSettingsController { controller in
            controller.showWindow()
            let windowContentView = try XCTUnwrap(controller.window?.contentView)
            let tableView = try XCTUnwrap(findSubview(in: windowContentView) { $0 is NSTableView } as? NSTableView)

            tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: tableView))
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            controller.window?.displayIfNeeded()

            let discoveredSubviews = allSubviews(in: windowContentView)
            let colorWells = discoveredSubviews.compactMap { $0 as? NSColorWell }
            let slider = try XCTUnwrap(
                discoveredSubviews
                    .compactMap { $0 as? NSSlider }
                    .first { $0.identifier?.rawValue == "terminalBackgroundOpacitySlider" }
            )
            let labels = discoveredSubviews.compactMap { $0 as? NSTextField }.map(\.stringValue)

            let identifiedColorWells = colorWells.filter {
                $0.identifier?.rawValue == "terminalForegroundColorWell" ||
                    $0.identifier?.rawValue == "terminalBackgroundColorWell"
            }

            XCTAssertEqual(identifiedColorWells.count, 2)
            XCTAssertGreaterThanOrEqual(slider.doubleValue, 0.0)
            XCTAssertLessThanOrEqual(slider.doubleValue, 1.0)
            XCTAssertTrue(labels.contains("Terminal Foreground:"))
            XCTAssertTrue(labels.contains("Terminal Background:"))
            XCTAssertTrue(labels.contains("Background Opacity:"))
        }
    }

    func testSettingsWindowAppearanceLabelsDoNotOverlapControls() throws {
        try withIsolatedSettingsController { controller in
            controller.showWindow()
            let windowContentView = try XCTUnwrap(controller.window?.contentView)
            let tableView = try XCTUnwrap(findSubview(in: windowContentView) { $0 is NSTableView } as? NSTableView)

            tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: tableView))
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            controller.window?.displayIfNeeded()

            let subviews = allSubviews(in: windowContentView)
            let labels = subviews.compactMap { $0 as? NSTextField }.filter {
                ["Terminal Foreground:", "Terminal Background:", "Background Opacity:"].contains($0.stringValue)
            }
            let controls = subviews.compactMap { view -> NSView? in
                if let colorWell = view as? NSColorWell,
                   let id = colorWell.identifier?.rawValue,
                   ["terminalForegroundColorWell", "terminalBackgroundColorWell"].contains(id) {
                    return colorWell
                }
                if let slider = view as? NSSlider, slider.identifier?.rawValue == "terminalBackgroundOpacitySlider" {
                    return slider
                }
                return nil
            }

            XCTAssertEqual(labels.count, 3)
            XCTAssertEqual(controls.count, 3)

            for label in labels {
                let overlappingControls = controls.filter { label.frame.intersects($0.frame) }
                XCTAssertTrue(overlappingControls.isEmpty, "Label \(label.stringValue) should not overlap any control")
            }
        }
    }

    func testSettingsWindowAppearanceChangesPersistToConfigFile() throws {
        try withTemporaryHomeDirectory { _ in
            PtermDirectories.ensureDirectories()

            let controller = SettingsWindowController()
            controller.showWindow()
            let windowContentView = try XCTUnwrap(controller.window?.contentView)
            let tableView = try XCTUnwrap(findSubview(in: windowContentView) { $0 is NSTableView } as? NSTableView)

            tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: tableView))

            let discoveredSubviews = allSubviews(in: windowContentView)
            let foregroundWell = try XCTUnwrap(
                discoveredSubviews
                    .compactMap { $0 as? NSColorWell }
                    .first { $0.identifier?.rawValue == "terminalForegroundColorWell" }
            )
            let backgroundWell = try XCTUnwrap(
                discoveredSubviews
                    .compactMap { $0 as? NSColorWell }
                    .first { $0.identifier?.rawValue == "terminalBackgroundColorWell" }
            )
            let slider = try XCTUnwrap(
                discoveredSubviews
                    .compactMap { $0 as? NSSlider }
                    .first { $0.identifier?.rawValue == "terminalBackgroundOpacitySlider" }
            )

            foregroundWell.color = NSColor(calibratedRed: 0xAA as CGFloat / 255.0,
                                           green: 0xBB as CGFloat / 255.0,
                                           blue: 0xCC as CGFloat / 255.0,
                                           alpha: 1.0)
            _ = foregroundWell.target?.perform(foregroundWell.action, with: foregroundWell)

            backgroundWell.color = NSColor(calibratedRed: 0x11 as CGFloat / 255.0,
                                           green: 0x22 as CGFloat / 255.0,
                                           blue: 0x33 as CGFloat / 255.0,
                                           alpha: 1.0)
            _ = backgroundWell.target?.perform(backgroundWell.action, with: backgroundWell)

            slider.doubleValue = 0.42
            _ = slider.target?.perform(slider.action, with: slider)

            let data = try Data(contentsOf: PtermDirectories.config)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let appearance = try XCTUnwrap(root["appearance"] as? [String: Any])
            let storedForeground = try XCTUnwrap(appearance["terminal_foreground_color"] as? String)
            let storedBackground = try XCTUnwrap(appearance["terminal_background_color"] as? String)
            let storedOpacity = try XCTUnwrap((appearance["terminal_background_opacity"] as? NSNumber)?.doubleValue)

            XCTAssertNotEqual(storedForeground, RGBColor.defaultTerminalForeground.hexString)
            XCTAssertNotEqual(storedBackground, RGBColor.defaultTerminalBackground.hexString)
            XCTAssertEqual(storedOpacity, 0.42, accuracy: 0.0001)

            let config = PtermConfigStore.load()
            XCTAssertEqual(config.terminalAppearance.foreground.hexString, storedForeground)
            XCTAssertEqual(config.terminalAppearance.background.hexString, storedBackground)
            XCTAssertEqual(config.terminalAppearance.backgroundOpacity, 0.42, accuracy: 0.0001)
        }
    }

    func testSettingsWindowFactoryResetPreservesUnknownKeysAndRestoresDefaults() throws {
        try withTemporaryHomeDirectory { _ in
            PtermDirectories.ensureDirectories()

            let seededConfig: [String: Any] = [
                "term": "vt100",
                "text_encoding": "utf-16",
                "memory_max": 12345678,
                "memory_initial": 2345678,
                "shells": [
                    "launch_order": ["/bin/bash", "/bin/sh"],
                    "preserved_shell_key": "keep"
                ],
                "text_interaction": [
                    "output_confirmed_input_animation": true,
                    "preserved_text_interaction_key": "keep"
                ],
                "font": ["name": "Menlo", "size": 17],
                "appearance": [
                    "terminal_foreground_color": "#123456",
                    "terminal_background_color": "#654321",
                    "terminal_background_opacity": 0.73,
                    "preserved_appearance_key": "keep"
                ],
                "session": [
                    "scroll_buffer_persistence": true,
                    "preserved_session_key": "keep"
                ],
                "security": [
                    "osc52_clipboard_read": true,
                    "paste_confirmation": false,
                    "preserved_security_key": "keep"
                ],
                "audit": [
                    "enabled": true,
                    "retention_days": 7,
                    "encryption": true,
                    "preserved_audit_key": "keep"
                ],
                "workspaces": [["name": "Keep Workspace"]],
                "shortcuts": ["zoom_in": "cmd+="],
                "custom_root_key": "keep"
            ]
            let seededData = try JSONSerialization.data(withJSONObject: seededConfig, options: [.prettyPrinted, .sortedKeys])
            try AtomicFileWriter.write(seededData, to: PtermDirectories.config, permissions: 0o600)

            let controller = SettingsWindowController()
            controller.resetToFactoryDefaults()

            let data = try Data(contentsOf: PtermDirectories.config)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

            XCTAssertNil(root["term"])
            XCTAssertNil(root["text_encoding"])
            XCTAssertNil(root["memory_max"])
            XCTAssertNil(root["memory_initial"])
            XCTAssertNil(root["font"])
            XCTAssertNil(root["font_name"])
            XCTAssertNil(root["font_size"])

            XCTAssertEqual(root["custom_root_key"] as? String, "keep")
            XCTAssertNotNil(root["workspaces"])
            XCTAssertNotNil(root["shortcuts"])

            let appearance = try XCTUnwrap(root["appearance"] as? [String: Any])
            XCTAssertNil(appearance["terminal_foreground_color"])
            XCTAssertNil(appearance["terminal_background_color"])
            XCTAssertNil(appearance["terminal_background_opacity"])
            XCTAssertEqual(appearance["preserved_appearance_key"] as? String, "keep")

            let session = try XCTUnwrap(root["session"] as? [String: Any])
            XCTAssertNil(session["scroll_buffer_persistence"])
            XCTAssertEqual(session["preserved_session_key"] as? String, "keep")

            let shells = try XCTUnwrap(root["shells"] as? [String: Any])
            XCTAssertNil(shells["launch_order"])
            XCTAssertEqual(shells["preserved_shell_key"] as? String, "keep")

            let textInteraction = try XCTUnwrap(root["text_interaction"] as? [String: Any])
            XCTAssertNil(textInteraction["output_confirmed_input_animation"])
            XCTAssertEqual(textInteraction["preserved_text_interaction_key"] as? String, "keep")

            let security = try XCTUnwrap(root["security"] as? [String: Any])
            XCTAssertNil(security["osc52_clipboard_read"])
            XCTAssertNil(security["paste_confirmation"])
            XCTAssertEqual(security["preserved_security_key"] as? String, "keep")

            let audit = try XCTUnwrap(root["audit"] as? [String: Any])
            XCTAssertNil(audit["enabled"])
            XCTAssertNil(audit["retention_days"])
            XCTAssertNil(audit["encryption"])
            XCTAssertEqual(audit["preserved_audit_key"] as? String, "keep")

            let loaded = PtermConfigStore.load()
            XCTAssertEqual(loaded.term, PtermConfig.default.term)
            XCTAssertEqual(loaded.textEncoding, PtermConfig.default.textEncoding)
            XCTAssertEqual(loaded.shellLaunch, PtermConfig.default.shellLaunch)
            XCTAssertEqual(loaded.textInteraction, PtermConfig.default.textInteraction)
            XCTAssertEqual(loaded.memoryMax, PtermConfig.default.memoryMax)
            XCTAssertEqual(loaded.terminalAppearance, PtermConfig.default.terminalAppearance)
        }
    }

    func testTerminalViewApplyAppearanceSettingsUpdatesClearColor() throws {
        let renderer = try makeRendererOrSkip()
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)

        renderer.updateTerminalAppearance(
            TerminalAppearanceConfiguration(
                foreground: RGBColor(red: 0xF0, green: 0xE0, blue: 0xD0),
                background: RGBColor(red: 0x11, green: 0x22, blue: 0x33),
                backgroundOpacity: 0.4
            )
        )
        view.applyAppearanceSettings()

        XCTAssertEqual(view.clearColor.red, Double(MetalRenderer.linearizeSRGBComponent(Float(0x11) / 255.0)), accuracy: 0.0001)
        XCTAssertEqual(view.clearColor.green, Double(MetalRenderer.linearizeSRGBComponent(Float(0x22) / 255.0)), accuracy: 0.0001)
        XCTAssertEqual(view.clearColor.blue, Double(MetalRenderer.linearizeSRGBComponent(Float(0x33) / 255.0)), accuracy: 0.0001)
        XCTAssertEqual(view.clearColor.alpha, 0.4, accuracy: 0.0001)
        XCTAssertFalse(view.isOpaque)
    }

    func testTerminalViewApplyAppearanceSettingsBecomesOpaqueAtFullOpacity() throws {
        let renderer = try makeRendererOrSkip()
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)

        renderer.updateTerminalAppearance(
            TerminalAppearanceConfiguration(
                foreground: .defaultTerminalForeground,
                background: RGBColor(red: 0x00, green: 0x00, blue: 0x00),
                backgroundOpacity: 1.0
            )
        )
        view.applyAppearanceSettings()

        XCTAssertEqual(view.clearColor.alpha, 1.0, accuracy: 0.0001)
        XCTAssertTrue(view.isOpaque)
        XCTAssertEqual(view.layer?.isOpaque, true)
    }

    func testTerminalViewUsesSRGBRenderTargetConfiguration() throws {
        let renderer = try makeRendererOrSkip()
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)

        XCTAssertEqual(view.colorPixelFormat, .bgra8Unorm_srgb)
        XCTAssertTrue(view.framebufferOnly)
        let metalLayer = try XCTUnwrap(view.layer as? CAMetalLayer)
        XCTAssertEqual(metalLayer.pixelFormat, .bgra8Unorm_srgb)
        XCTAssertEqual(metalLayer.colorspace?.name as String?, CGColorSpace.sRGB as String)
        if #available(macOS 10.13.2, *) {
            XCTAssertEqual(metalLayer.maximumDrawableCount, 2)
        }
    }

    func testMetalRendererTerminalClearColorLinearizesSRGBBackground() throws {
        let renderer = try makeRendererOrSkip()
        renderer.updateTerminalAppearance(
            TerminalAppearanceConfiguration(
                foreground: .defaultTerminalForeground,
                background: RGBColor(red: 236, green: 103, blue: 101),
                backgroundOpacity: 1.0
            )
        )

        let expectedR = MetalRenderer.linearizeSRGBComponent(236.0 / 255.0)
        let expectedG = MetalRenderer.linearizeSRGBComponent(103.0 / 255.0)
        let expectedB = MetalRenderer.linearizeSRGBComponent(101.0 / 255.0)

        XCTAssertEqual(renderer.terminalClearColor.red, Double(expectedR), accuracy: 0.0001)
        XCTAssertEqual(renderer.terminalClearColor.green, Double(expectedG), accuracy: 0.0001)
        XCTAssertEqual(renderer.terminalClearColor.blue, Double(expectedB), accuracy: 0.0001)
        XCTAssertEqual(renderer.terminalClearColor.alpha, 1.0, accuracy: 0.0001)
    }

    func testIntegratedViewApplyAppearanceSettingsUpdatesClearColor() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), renderer: renderer, manager: manager)

        renderer.updateTerminalAppearance(
            TerminalAppearanceConfiguration(
                foreground: RGBColor(red: 0xF0, green: 0xE0, blue: 0xD0),
                background: RGBColor(red: 0x12, green: 0x34, blue: 0x56),
                backgroundOpacity: 0.35
            )
        )
        view.applyAppearanceSettings()

        XCTAssertEqual(view.clearColor.red, 0.0, accuracy: 0.0001)
        XCTAssertEqual(view.clearColor.green, 0.0, accuracy: 0.0001)
        XCTAssertEqual(view.clearColor.blue, 0.0, accuracy: 0.0001)
        XCTAssertEqual(view.clearColor.alpha, 0.0, accuracy: 0.0001)
    }

    func testTerminalViewImagePreviewClampFitsWithin640By480() {
        let size = TerminalView.clampedImagePreviewSize(
            for: NSSize(width: 4000, height: 2000)
        )

        XCTAssertEqual(size.width, 640, accuracy: 0.0001)
        XCTAssertEqual(size.height, 320, accuracy: 0.0001)
    }

    func testTerminalViewImagePreviewClampPreservesSmallerImages() {
        let size = TerminalView.clampedImagePreviewSize(
            for: NSSize(width: 320, height: 200)
        )

        XCTAssertEqual(size.width, 320, accuracy: 0.0001)
        XCTAssertEqual(size.height, 200, accuracy: 0.0001)
    }

    func testTerminalViewImagePreviewWindowIsReleasedWhenPreviewHides() throws {
        let renderer = try makeRendererOrSkip()
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), renderer: renderer)

        view.debugInstallImagePreviewWindowForTesting()
        XCTAssertTrue(view.hasActiveImagePreviewWindow)

        view.debugReleaseImagePreviewWindowNow()
        XCTAssertFalse(view.hasActiveImagePreviewWindow)
    }

    func testIntegratedViewUsesSRGBRenderTargetConfiguration() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), renderer: renderer, manager: manager)

        XCTAssertEqual(view.colorPixelFormat, .bgra8Unorm_srgb)
        XCTAssertTrue(view.framebufferOnly)
        let metalLayer = try XCTUnwrap(view.layer as? CAMetalLayer)
        XCTAssertEqual(metalLayer.pixelFormat, .bgra8Unorm_srgb)
        XCTAssertEqual(metalLayer.colorspace?.name as String?, CGColorSpace.sRGB as String)
        if #available(macOS 10.13.2, *) {
            XCTAssertEqual(metalLayer.maximumDrawableCount, 2)
        }
    }

    func testGlyphAtlasStartsAtSmallTextureAndGrowsOnlyWhenNeeded() throws {
        let renderer = try makeRendererOrSkip()
        let atlas = GlyphAtlas(
            device: renderer.device,
            fontSize: 11,
            scaleFactor: 2.0,
            initialAtlasDimension: 32,
            maxAtlasDimension: 128,
            prerasterizeASCII: false
        )

        XCTAssertEqual(atlas.atlasDimension, 32)
        XCTAssertNil(atlas.texturePixelSize)

        _ = atlas.glyphInfo(for: 65)

        var codepoint: UInt32 = 0x80
        while atlas.atlasDimension == 32 && codepoint < 0x400 {
            _ = atlas.glyphInfo(for: codepoint)
            codepoint += 1
        }

        XCTAssertGreaterThan(atlas.atlasDimension, 32)
        XCTAssertNotNil(atlas.glyphCache[65])
        XCTAssertEqual(
            atlas.texturePixelSize?.width,
            atlas.atlasDimension * Int(max(atlas.scaleFactor, 2.0))
        )
    }

    func testGlyphAtlasGrowthUsesSmallerStepThanDoubling() throws {
        let renderer = try makeRendererOrSkip()
        let atlas = GlyphAtlas(
            device: renderer.device,
            fontSize: 11,
            scaleFactor: 2.0,
            initialAtlasDimension: 32,
            maxAtlasDimension: 128,
            prerasterizeASCII: false
        )

        var codepoint: UInt32 = 0x80
        while atlas.atlasDimension == 32 && codepoint < 0x400 {
            _ = atlas.glyphInfo(for: codepoint)
            codepoint += 1
        }

        XCTAssertEqual(atlas.atlasDimension, 48)
        XCTAssertEqual(atlas.texturePixelSize?.width, 96)
        XCTAssertEqual(atlas.texturePixelSize?.height, 96)
    }

    func testGlyphAtlasResetToMinimumClearsCacheAndRestoresInitialTextureSize() throws {
        let renderer = try makeRendererOrSkip()
        let atlas = GlyphAtlas(
            device: renderer.device,
            fontSize: 11,
            scaleFactor: 2.0,
            initialAtlasDimension: 32,
            maxAtlasDimension: 128,
            prerasterizeASCII: false
        )

        var codepoint: UInt32 = 0x80
        while atlas.atlasDimension == 32 && codepoint < 0x400 {
            _ = atlas.glyphInfo(for: codepoint)
            codepoint += 1
        }
        XCTAssertGreaterThan(atlas.atlasDimension, 32)
        XCTAssertGreaterThan(atlas.glyphCache.count, 0)

        atlas.resetToMinimum()

        XCTAssertEqual(atlas.atlasDimension, 32)
        XCTAssertNil(atlas.texturePixelSize)
        XCTAssertEqual(atlas.glyphCache.count, 0)
    }

    func testGlyphAtlasDoesNotSeedASCIIByDefault() throws {
        let renderer = try makeRendererOrSkip()
        let atlas = GlyphAtlas(
            device: renderer.device,
            fontSize: 11,
            scaleFactor: 2.0
        )

        XCTAssertEqual(atlas.glyphCache.count, 0)
        XCTAssertNil(atlas.glyphCache[65])
        XCTAssertNil(atlas.texturePixelSize)
    }

    func testGlyphAtlasAllocatesTextureOnlyWhenFirstGlyphIsRasterized() throws {
        let renderer = try makeRendererOrSkip()
        let atlas = GlyphAtlas(
            device: renderer.device,
            fontSize: 11,
            scaleFactor: 2.0,
            initialAtlasDimension: 32,
            maxAtlasDimension: 128,
            prerasterizeASCII: false
        )

        XCTAssertNil(atlas.texturePixelSize)

        _ = atlas.glyphInfo(for: 65)

        XCTAssertEqual(atlas.texturePixelSize?.width, 64)
        XCTAssertEqual(atlas.texturePixelSize?.height, 64)
    }

    func testGlyphAtlasDefersCommandQueueAllocationUntilSynchronizationIsNeeded() throws {
        let renderer = try makeRendererOrSkip()
        let atlas = GlyphAtlas(
            device: renderer.device,
            fontSize: 11,
            scaleFactor: 2.0,
            initialAtlasDimension: 32,
            maxAtlasDimension: 128,
            prerasterizeASCII: false
        )

        XCTAssertFalse(atlas.debugHasCommandQueue)

        _ = atlas.glyphInfo(for: 65)

        if renderer.device.hasUnifiedMemory {
            XCTAssertFalse(atlas.debugHasCommandQueue)
        }
    }

    func testGlyphAtlasDefaultInitialAllocationUsesCompactTextureSize() throws {
        let renderer = try makeRendererOrSkip()
        let atlas = GlyphAtlas(
            device: renderer.device,
            fontSize: 11,
            scaleFactor: 2.0
        )

        XCTAssertNil(atlas.texturePixelSize)

        _ = atlas.glyphInfo(for: 65)

        XCTAssertEqual(atlas.atlasDimension, 128)
        XCTAssertEqual(atlas.texturePixelSize?.width, 256)
        XCTAssertEqual(atlas.texturePixelSize?.height, 256)
    }

    func testGlyphAtlasPrerasterizedASCIICanBeDisabledAcrossRebuilds() throws {
        let renderer = try makeRendererOrSkip()
        let atlas = GlyphAtlas(
            device: renderer.device,
            fontSize: 11,
            scaleFactor: 2.0,
            prerasterizeASCII: false
        )

        _ = atlas.glyphInfo(for: 65)
        XCTAssertNotNil(atlas.glyphCache[65])

        atlas.updateScaleFactor(1.0)

        XCTAssertEqual(Set(atlas.glyphCache.keys), [65])
    }

    func testGlyphAtlasIdleCompactionDropsUnusedGlyphsAndCanShrinkTexture() throws {
        let renderer = try makeRendererOrSkip()
        let atlas = GlyphAtlas(
            device: renderer.device,
            fontSize: 11,
            scaleFactor: 2.0,
            initialAtlasDimension: 32,
            maxAtlasDimension: 128,
            prerasterizeASCII: false
        )

        _ = atlas.glyphInfo(for: 65)
        var codepoint: UInt32 = 0x80
        while atlas.atlasDimension == 32 && codepoint < 0x400 {
            _ = atlas.glyphInfo(for: codepoint)
            codepoint += 1
        }
        let grownDimension = atlas.atlasDimension
        let grownPixelSize = atlas.texturePixelSize
        XCTAssertGreaterThan(grownDimension, 32)
        XCTAssertGreaterThan(atlas.glyphCache.count, 1)

        for _ in 0..<64 {
            _ = atlas.glyphInfo(for: 65)
        }
        XCTAssertTrue(atlas.compactRetainingRecentlyUsedGlyphs(maximumInactiveGenerations: 8))

        XCTAssertEqual(Set(atlas.glyphCache.keys), [65])
        XCTAssertLessThan(atlas.atlasDimension, grownDimension)
        XCTAssertLessThan(atlas.texturePixelSize?.width ?? .max, grownPixelSize?.width ?? .max)
        XCTAssertLessThan(atlas.texturePixelSize?.height ?? .max, grownPixelSize?.height ?? .max)
    }

    func testGlyphAtlasCompactionRetainsMostRecentlyTouchedGlyph() throws {
        let renderer = try makeRendererOrSkip()
        let atlas = GlyphAtlas(
            device: renderer.device,
            fontSize: 11,
            scaleFactor: 2.0,
            initialAtlasDimension: 32,
            maxAtlasDimension: 128,
            prerasterizeASCII: false
        )

        _ = atlas.glyphInfo(for: 65)
        _ = atlas.glyphInfo(for: 66)
        XCTAssertEqual(Set(atlas.glyphCache.keys), [65, 66])

        for _ in 0..<64 {
            _ = atlas.glyphInfo(for: 66)
        }

        XCTAssertTrue(atlas.compactRetainingRecentlyUsedGlyphs(maximumInactiveGenerations: 8))
        XCTAssertEqual(Set(atlas.glyphCache.keys), [66])
    }

    func testIntegratedViewCloseButtonColorUsesDisplayP3ToSRGBConversion() {
        let expectedCircle = NSColor(displayP3Red: 236.0 / 255.0, green: 103.0 / 255.0, blue: 101.0 / 255.0, alpha: 1.0)
            .usingColorSpace(.sRGB) ?? .systemRed
        let actualCircle = IntegratedView.macOSCloseButtonCircleColor()
        XCTAssertEqual(actualCircle.r, Float(expectedCircle.redComponent), accuracy: 0.0001)
        XCTAssertEqual(actualCircle.g, Float(expectedCircle.greenComponent), accuracy: 0.0001)
        XCTAssertEqual(actualCircle.b, Float(expectedCircle.blueComponent), accuracy: 0.0001)

        let expectedIcon = NSColor(displayP3Red: 119.0 / 255.0, green: 52.0 / 255.0, blue: 50.0 / 255.0, alpha: 1.0)
            .usingColorSpace(.sRGB) ?? .black
        let actualIcon = IntegratedView.macOSCloseButtonIconColor()
        XCTAssertEqual(actualIcon.r, Float(expectedIcon.redComponent), accuracy: 0.0001)
        XCTAssertEqual(actualIcon.g, Float(expectedIcon.greenComponent), accuracy: 0.0001)
        XCTAssertEqual(actualIcon.b, Float(expectedIcon.blueComponent), accuracy: 0.0001)
    }

    func testIntegratedViewSRGBColorHelperPreservesSRGBComponents() {
        let expected = NSColor(srgbRed: 0.20, green: 0.24, blue: 0.20, alpha: 1.0)
            .usingColorSpace(.sRGB) ?? .black
        let actual = IntegratedView.srgbColor(red: 0.20, green: 0.24, blue: 0.20)

        XCTAssertEqual(actual.r, Float(expected.redComponent), accuracy: 0.0001)
        XCTAssertEqual(actual.g, Float(expected.greenComponent), accuracy: 0.0001)
        XCTAssertEqual(actual.b, Float(expected.blueComponent), accuracy: 0.0001)
    }

    func testTerminalViewStartsInDemandDrivenRenderingMode() throws {
        let renderer = try makeRendererOrSkip()
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)

        XCTAssertTrue(view.demandDrivenRendering)
        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(view.enableSetNeedsDisplay)
    }

    func testSplitTerminalContainerApplyAppearanceSettingsPropagatesClearColor() throws {
        let renderer = try makeRendererOrSkip()
        let controllers = [
            TerminalController(rows: 4, cols: 12, termEnv: "xterm-256color", textEncoding: .utf8, scrollbackInitialCapacity: 4096, scrollbackMaxCapacity: 4096, fontName: "Menlo", fontSize: 13),
            TerminalController(rows: 4, cols: 12, termEnv: "xterm-256color", textEncoding: .utf8, scrollbackInitialCapacity: 4096, scrollbackMaxCapacity: 4096, fontName: "Menlo", fontSize: 13)
        ]
        let container = SplitTerminalContainerView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 280),
            renderer: renderer,
            controllers: controllers
        )

        renderer.updateTerminalAppearance(
            TerminalAppearanceConfiguration(
                foreground: .defaultTerminalForeground,
                background: RGBColor(red: 0x20, green: 0x40, blue: 0x60),
                backgroundOpacity: 0.5
            )
        )
        container.applyAppearanceSettings()

        let terminalViews = allSubviews(in: container).compactMap { $0 as? TerminalView }
        let splitRenderView = try XCTUnwrap(allSubviews(in: container).compactMap { $0 as? SplitRenderView }.first)

        XCTAssertTrue(terminalViews.allSatisfy { abs($0.clearColor.alpha - 0.5) < 0.0001 })
        XCTAssertEqual(splitRenderView.clearColor.alpha, 0.5, accuracy: 0.0001)
    }

    func testSplitRenderViewApplyAppearanceSettingsBecomesOpaqueAtFullOpacity() throws {
        let renderer = try makeRendererOrSkip()
        let view = SplitRenderView(frame: NSRect(x: 0, y: 0, width: 480, height: 280), renderer: renderer)

        renderer.updateTerminalAppearance(
            TerminalAppearanceConfiguration(
                foreground: .defaultTerminalForeground,
                background: RGBColor(red: 0x00, green: 0x00, blue: 0x00),
                backgroundOpacity: 1.0
            )
        )
        view.applyAppearanceSettings()

        XCTAssertEqual(view.clearColor.alpha, 1.0, accuracy: 0.0001)
        XCTAssertTrue(view.isOpaque)
        XCTAssertEqual(view.layer?.isOpaque, true)
    }

    func testSplitRenderViewUsesSRGBRenderTargetConfiguration() throws {
        let renderer = try makeRendererOrSkip()
        let view = SplitRenderView(frame: NSRect(x: 0, y: 0, width: 480, height: 280), renderer: renderer)

        XCTAssertEqual(view.colorPixelFormat, .bgra8Unorm_srgb)
        XCTAssertTrue(view.framebufferOnly)
        let metalLayer = try XCTUnwrap(view.layer as? CAMetalLayer)
        XCTAssertEqual(metalLayer.pixelFormat, .bgra8Unorm_srgb)
        XCTAssertEqual(metalLayer.colorspace?.name as String?, CGColorSpace.sRGB as String)
        if #available(macOS 10.13.2, *) {
            XCTAssertEqual(metalLayer.maximumDrawableCount, 2)
        }
    }

    func testSplitRenderViewStartsInDemandDrivenRenderingMode() throws {
        let renderer = try makeRendererOrSkip()
        let view = SplitRenderView(frame: NSRect(x: 0, y: 0, width: 480, height: 280), renderer: renderer)

        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(view.enableSetNeedsDisplay)
    }

    func testTerminalViewOutputPulseTimerTracksActiveOutputState() throws {
        let renderer = try makeRendererOrSkip()
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)

        XCTAssertFalse(view.debugHasOutputPulseTimer)

        view.isOutputActive = true
        XCTAssertTrue(view.debugHasOutputPulseTimer)

        view.isOutputActive = false
        XCTAssertFalse(view.debugHasOutputPulseTimer)
    }

    func testSplitRenderViewOutputPulseTimerTracksActiveOutputState() throws {
        let renderer = try makeRendererOrSkip()
        let view = SplitRenderView(frame: NSRect(x: 0, y: 0, width: 480, height: 280), renderer: renderer)

        XCTAssertFalse(view.debugHasOutputPulseTimer)

        view.hasActiveOutput = true
        XCTAssertTrue(view.debugHasOutputPulseTimer)

        view.hasActiveOutput = false
        XCTAssertFalse(view.debugHasOutputPulseTimer)
    }

    func testSearchBarViewUpdatesCountAndInvokesCallbacks() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        var queries: [String] = []
        var didNavigate = false
        var didClose = false
        view.onQueryChange = { queries.append($0) }
        view.onNavigateNext = { didNavigate = true }
        view.onClose = { didClose = true }
        view.layoutSubtreeIfNeeded()

        guard let searchField = view.subviews.compactMap({ $0 as? NSSearchField }).first,
              let countLabel = view.subviews.compactMap({ $0 as? NSTextField }).first(where: { !($0 is NSSearchField) }) else {
            XCTFail("Search bar subviews missing")
            return
        }

        searchField.stringValue = "error"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        XCTAssertEqual(queries, ["error"])

        view.updateCount(current: 2, total: 5)
        XCTAssertEqual(countLabel.stringValue, "2/5")
        view.updateCount(current: nil, total: 0)
        XCTAssertEqual(countLabel.stringValue, "0")

        searchField.performClick(nil)
        XCTAssertTrue(didNavigate)

        view.cancelOperation(nil)
        XCTAssertTrue(didClose)
    }

    func testSearchBarSubmitActionInvokesNavigateNext() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        var navigateCount = 0
        view.onNavigateNext = { navigateCount += 1 }

        guard let searchField = allSubviews(in: view).compactMap({ $0 as? NSSearchField }).first else {
            XCTFail("Search field missing")
            return
        }

        searchField.sendAction(searchField.action, to: searchField.target)

        XCTAssertEqual(navigateCount, 1)
    }

    func testSearchBarQueryChangePublishesEmptyStringWhenCleared() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        var queries: [String] = []
        view.onQueryChange = { queries.append($0) }

        guard let searchField = allSubviews(in: view).compactMap({ $0 as? NSSearchField }).first else {
            XCTFail("Search field missing")
            return
        }

        searchField.stringValue = "error"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        searchField.stringValue = ""
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))

        XCTAssertEqual(queries, ["error", ""])
    }

    func testSearchBarCancelOperationDoesNotClearExistingQueryText() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        var didClose = false
        view.onClose = { didClose = true }

        guard let searchField = allSubviews(in: view).compactMap({ $0 as? NSSearchField }).first else {
            XCTFail("Search field missing")
            return
        }

        searchField.stringValue = "error"
        view.cancelOperation(nil)

        XCTAssertTrue(didClose)
        XCTAssertEqual(searchField.stringValue, "error")
    }

    func testSearchBarUsesExpectedPlaceholder() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))

        let searchField = allSubviews(in: view).compactMap { $0 as? NSSearchField }.first

        XCTAssertEqual(searchField?.placeholderString, "Search")
    }

    func testSearchBarFocusMakesSearchFieldFirstResponder() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.frame.origin = NSPoint(x: 10, y: 10)
        window.makeKeyAndOrderFront(nil)

        guard let searchField = allSubviews(in: view).compactMap({ $0 as? NSSearchField }).first else {
            XCTFail("Search field missing")
            return
        }

        view.focus()

        XCTAssertTrue(window.firstResponder === searchField.currentEditor() || window.firstResponder === searchField)
    }

    func testSearchBarFocusPreservesExistingQueryText() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)

        guard let searchField = allSubviews(in: view).compactMap({ $0 as? NSSearchField }).first else {
            XCTFail("Search field missing")
            return
        }

        searchField.stringValue = "error"
        view.focus()

        XCTAssertEqual(searchField.stringValue, "error")
    }

    func testTerminalViewMarkedTextShowsIMEOverlayAndRange() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller

        view.setMarkedText("日本語", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.updateMarkedTextOverlayPublic()

        let textLayer = view.layer?.sublayers?.compactMap { $0 as? CATextLayer }.first
        let rendered = textLayer?.string as? NSAttributedString

        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 3))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertEqual(rendered?.string, "日本語")
        XCTAssertEqual(textLayer?.isHidden, false)
        XCTAssertGreaterThan(textLayer?.frame.width ?? 0, 0)
    }

    func testTerminalViewDoesNotCreateMarkedTextLayerUntilIMECompositionBegins() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller

        XCTAssertTrue(view.layer?.sublayers?.compactMap { $0 as? CATextLayer }.isEmpty ?? true)
        XCTAssertFalse(view.debugHasMarkedTextStorage)

        view.setMarkedText("かな", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(view.layer?.sublayers?.compactMap { $0 as? CATextLayer }.count, 1)
        XCTAssertTrue(view.debugHasMarkedTextStorage)
    }

    func testTerminalViewReleasesMarkedTextStorageWhenCompositionEnds() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller

        XCTAssertFalse(view.debugHasMarkedTextStorage)
        view.setMarkedText("かな", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.debugHasMarkedTextStorage)

        view.unmarkText()
        XCTAssertFalse(view.debugHasMarkedTextStorage)

        view.setMarkedText("かな", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.debugHasMarkedTextStorage)
        view.insertText("かな", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.debugHasMarkedTextStorage)
    }

    func testTerminalViewDefersKeyboardHandlerAllocationUntilInputHandlingBegins() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller

        XCTAssertFalse(view.debugHasKeyboardHandler)
        view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(view.debugHasKeyboardHandler)
    }

    func testTerminalViewIdlePurgeReleasesKeyboardHandlerAndRecreatesItOnNextInput() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller

        view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(view.debugHasKeyboardHandler)

        view.debugReleaseIdleBuffersNow()
        XCTAssertFalse(view.debugHasKeyboardHandler)

        view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(view.debugHasKeyboardHandler)
    }

    func testTerminalViewInactiveReleaseReleasesKeyboardHandler() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller

        view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(view.debugHasKeyboardHandler)

        view.releaseInactiveRenderingResourcesNow()
        XCTAssertFalse(view.debugHasKeyboardHandler)
    }

    func testTerminalViewInsertTextClearsMarkedTextAndHidesIMEOverlay() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller

        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.layer?.sublayers?.compactMap { $0 as? CATextLayer }.isEmpty ?? true)
    }

    func testTerminalViewPlainInsertTextShowsTransientCommittedTextPreview() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller

        view.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertTrue(view.debugHasCommittedTextPreview)
    }

    func testTerminalViewDeleteBackwardShowsTransientFadeOutPreview() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        controller.withModel { model in
            model.grid.setCell(Cell(codepoint: 65, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 0)
            model.cursor.row = 0
            model.cursor.col = 1
        }
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller

        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertTrue(view.debugHasCommittedTextPreview)
    }

    func testTerminalViewCommittedTextPreviewQueueCapsAtThirtyEntries() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 80,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller

        for _ in 0..<40 {
            view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        XCTAssertEqual(view.debugCommittedTextPreviewCount, 30)
    }

    func testTerminalViewKeyDownFallbackEnqueuesOutputConfirmedInsertIntentForPrintableText() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 80,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        view.outputConfirmedInputAnimationsEnabled = true
        view.debugSetSuppressInterpretKeyEvents(true)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))

        view.keyDown(with: event)

        XCTAssertEqual(view.debugPendingCommittedTextIntentCount, 1)
        XCTAssertTrue(view.debugHasPendingIntentResolutionTimer)
    }

    func testTerminalViewKeyDownFallbackDoesNotEnqueueIntentForArrowKeys() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 80,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        view.outputConfirmedInputAnimationsEnabled = true
        view.debugSetSuppressInterpretKeyEvents(true)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: String(UnicodeScalar(NSUpArrowFunctionKey)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSUpArrowFunctionKey)!),
            isARepeat: false,
            keyCode: 126
        ))

        view.keyDown(with: event)

        XCTAssertEqual(view.debugPendingCommittedTextIntentCount, 0)
    }

    func testTerminalViewKeyDownFallbackEnqueuesOutputConfirmedDeleteIntentForBackspace() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 80,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        controller.withModel { model in
            model.grid.setCell(Cell(codepoint: 97, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: 0)
            model.cursor.row = 0
            model.cursor.col = 1
        }
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        view.outputConfirmedInputAnimationsEnabled = true
        view.debugSetSuppressInterpretKeyEvents(true)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: String(UnicodeScalar(0x7F)!),
            charactersIgnoringModifiers: String(UnicodeScalar(0x7F)!),
            isARepeat: false,
            keyCode: 51
        ))

        view.keyDown(with: event)

        XCTAssertEqual(view.debugPendingCommittedTextIntentCount, 1)
    }

    func testTerminalViewKeyDownFallbackEnqueuesDeleteIntentFromRecentInsertionHistory() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 80,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        view.outputConfirmedInputAnimationsEnabled = false

        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.withModel { model in
            for col in 0..<model.cols {
                model.grid.setCell(.empty, at: 0, col: col)
            }
            model.cursor.row = 0
            model.cursor.col = 0
        }

        view.outputConfirmedInputAnimationsEnabled = true
        view.debugSetSuppressInterpretKeyEvents(true)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: String(UnicodeScalar(0x7F)!),
            charactersIgnoringModifiers: String(UnicodeScalar(0x7F)!),
            isARepeat: false,
            keyCode: 51
        ))

        view.keyDown(with: event)

        XCTAssertEqual(view.debugPendingCommittedTextIntentCount, 1)
    }

    func testTerminalViewKeyDownFallbackDeleteIntentUsesRecentInsertionHistoryAfterDelay() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 80,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        view.outputConfirmedInputAnimationsEnabled = false

        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.withModel { model in
            for col in 0..<model.cols {
                model.grid.setCell(.empty, at: 0, col: col)
            }
            model.cursor.row = 0
            model.cursor.col = 0
        }

        Thread.sleep(forTimeInterval: 2.1)

        view.outputConfirmedInputAnimationsEnabled = true
        view.debugSetSuppressInterpretKeyEvents(true)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: String(UnicodeScalar(0x7F)!),
            charactersIgnoringModifiers: String(UnicodeScalar(0x7F)!),
            isARepeat: false,
            keyCode: 51
        ))

        view.keyDown(with: event)

        XCTAssertEqual(view.debugPendingCommittedTextIntentCount, 1)
    }

    func testTerminalViewKeyDownFallbackDeleteIntentUsesLastCharacterOfRecentMulticharInsertion() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 80,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        view.outputConfirmedInputAnimationsEnabled = false

        view.insertText("あああ", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.withModel { model in
            for col in 0..<model.cols {
                model.grid.setCell(.empty, at: 0, col: col)
            }
            model.cursor.row = 0
            model.cursor.col = 0
        }

        view.outputConfirmedInputAnimationsEnabled = true
        view.debugSetSuppressInterpretKeyEvents(true)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: String(UnicodeScalar(0x7F)!),
            charactersIgnoringModifiers: String(UnicodeScalar(0x7F)!),
            isARepeat: false,
            keyCode: 51
        ))

        view.keyDown(with: event)

        XCTAssertEqual(view.debugPendingCommittedTextIntentCount, 1)
        XCTAssertEqual(view.debugLastPendingCommittedTextIntentText, "あ")
    }

    func testTerminalViewOutputConfirmedInsertSeedsRecentHistoryForLaterWideDelete() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 80,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        view.outputConfirmedInputAnimationsEnabled = true

        view.insertText("あああ", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.withModel { model in
            for col in 0..<model.cols {
                model.grid.setCell(.empty, at: 0, col: col)
            }
            model.cursor.row = 0
            model.cursor.col = 0
        }

        view.debugSetSuppressInterpretKeyEvents(true)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: String(UnicodeScalar(0x7F)!),
            charactersIgnoringModifiers: String(UnicodeScalar(0x7F)!),
            isARepeat: false,
            keyCode: 51
        ))

        view.keyDown(with: event)

        XCTAssertEqual(view.debugPendingCommittedTextIntentCount, 2)
        XCTAssertEqual(view.debugLastPendingCommittedTextIntentText, "あ")
    }

    func testTerminalViewOutputConfirmedIMECommitEnqueuesInsertIntentAfterUnmarking() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 80,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 160), renderer: renderer)
        view.terminalController = controller
        view.outputConfirmedInputAnimationsEnabled = true

        view.setMarkedText("あああ", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        view.insertText("あああ", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(view.debugPendingCommittedTextIntentCount, 1)
        XCTAssertEqual(view.debugLastPendingCommittedTextIntentText, "あああ")
        XCTAssertFalse(view.hasMarkedText())
    }

    func testTerminalViewUnmarkTextClearsIMEOverlayAndSelectionState() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller

        view.setMarkedText("未確定", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()

        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertTrue(view.layer?.sublayers?.compactMap { $0 as? CATextLayer }.isEmpty ?? true)
    }

    func testTerminalViewAttributedSubstringReturnsRequestedMarkedTextSegment() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        view.terminalController = controller

        view.setMarkedText("abcdef", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        var actual = NSRange(location: NSNotFound, length: 0)
        let slice = view.attributedSubstring(forProposedRange: NSRange(location: 2, length: 3), actualRange: &actual)

        XCTAssertEqual(slice?.string, "cde")
        XCTAssertEqual(actual, NSRange(location: 2, length: 3))
    }

    func testTerminalViewSyncScaleFactorUpdatesAtlasAndMarkedTextLayerScale() throws {
        guard let renderer = MetalRenderer(scaleFactor: 1.0) else {
            throw XCTSkip("Metal unavailable")
        }
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        view.setMarkedText("IME", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        view.syncScaleFactorIfNeeded()

        let scale = window.backingScaleFactor
        let textLayer = view.layer?.sublayers?.compactMap { $0 as? CATextLayer }.first

        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, scale)
        XCTAssertEqual(textLayer?.contentsScale, scale)
    }

    func testTerminalViewRespondsToSimulatedDisplayScaleChange() throws {
        guard let renderer = MetalRenderer(scaleFactor: 1.0) else {
            throw XCTSkip("Metal unavailable")
        }
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        view.setMarkedText("IME", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        view.viewDidMoveToWindow()
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 1.0)

        window.testBackingScaleFactor = 2.5
        view.viewDidChangeBackingProperties()

        let textLayer = view.layer?.sublayers?.compactMap { $0 as? CATextLayer }.first
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 2.5)
        XCTAssertEqual(textLayer?.contentsScale, 2.5)
    }

    func testTerminalViewMarkedTextOverlaySurvivesRepeatedDisplayScaleChangesDuringIMEComposition() throws {
        guard let renderer = MetalRenderer(scaleFactor: 1.0) else {
            throw XCTSkip("Metal unavailable")
        }
        let controller = TerminalController(
            rows: 6,
            cols: 16,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 360, height: 200), renderer: renderer)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        view.setMarkedText("日本語", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.updateMarkedTextOverlayPublic()

        for scale in [1.0 as CGFloat, 2.0, 1.5, 3.0] {
            window.testBackingScaleFactor = scale
            view.viewDidChangeBackingProperties()
            view.updateMarkedTextOverlayPublic()

            let textLayer = try XCTUnwrap(view.layer?.sublayers?.compactMap { $0 as? CATextLayer }.first)
            let rendered = try XCTUnwrap(textLayer.string as? NSAttributedString)
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertEqual(rendered.string, "日本語")
            XCTAssertEqual(renderer.glyphAtlas.scaleFactor, scale)
            XCTAssertEqual(textLayer.contentsScale, scale)
            XCTAssertFalse(textLayer.isHidden)
            XCTAssertGreaterThan(textLayer.frame.width, 0)
            XCTAssertGreaterThan(textLayer.frame.height, 0)
        }
    }

    func testTerminalViewInsertTextAfterDisplayScaleChangeClearsMarkedTextWhileKeepingUpdatedScale() throws {
        guard let renderer = MetalRenderer(scaleFactor: 1.0) else {
            throw XCTSkip("Metal unavailable")
        }
        let controller = TerminalController(
            rows: 6,
            cols: 16,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 360, height: 200), renderer: renderer)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        view.setMarkedText("かな", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        window.testBackingScaleFactor = 2.0
        view.viewDidChangeBackingProperties()
        view.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 2.0)
        XCTAssertTrue(view.layer?.sublayers?.compactMap { $0 as? CATextLayer }.isEmpty ?? true)
    }

    func testTerminalViewUnmarkTextAfterDisplayScaleChangeClearsOverlayWhileKeepingUpdatedScale() throws {
        guard let renderer = MetalRenderer(scaleFactor: 1.0) else {
            throw XCTSkip("Metal unavailable")
        }
        let controller = TerminalController(
            rows: 6,
            cols: 16,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 360, height: 200), renderer: renderer)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        view.setMarkedText("未確定", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        window.testBackingScaleFactor = 2.5
        view.viewDidChangeBackingProperties()
        view.unmarkText()

        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 2.5)
        XCTAssertTrue(view.layer?.sublayers?.compactMap { $0 as? CATextLayer }.isEmpty ?? true)
    }

    func testTerminalViewUnmarkTextReleasesMarkedTextLayerStorage() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller

        view.setMarkedText("未確定", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.layer?.sublayers?.compactMap { $0 as? CATextLayer }.count, 1)

        view.unmarkText()

        XCTAssertTrue(view.layer?.sublayers?.compactMap { $0 as? CATextLayer }.isEmpty ?? true)
    }

    func testTerminalViewAttributedSubstringAfterDisplayScaleChangePreservesMarkedTextRange() throws {
        guard let renderer = MetalRenderer(scaleFactor: 1.0) else {
            throw XCTSkip("Metal unavailable")
        }
        let controller = TerminalController(
            rows: 6,
            cols: 16,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 360, height: 200), renderer: renderer)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        view.setMarkedText("abcdef", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        window.testBackingScaleFactor = 2.0
        view.viewDidChangeBackingProperties()

        var actual = NSRange(location: NSNotFound, length: 0)
        let slice = view.attributedSubstring(forProposedRange: NSRange(location: 1, length: 4), actualRange: &actual)
        let textLayer = try XCTUnwrap(view.layer?.sublayers?.compactMap { $0 as? CATextLayer }.first)

        XCTAssertEqual(slice?.string, "bcde")
        XCTAssertEqual(actual, NSRange(location: 1, length: 4))
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 2.0)
        XCTAssertEqual(textLayer.contentsScale, 2.0)
    }

    func testTerminalViewMetalDrawKeepsDrawableAliveAcrossScrollTransitions() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        controller.scrollback.appendRow(ArraySlice("SCROLLTOP".unicodeScalars.map {
            Cell(codepoint: $0.value, attributes: .default, width: 1, isWideContinuation: false)
        }), isWrapped: false)
        controller.withModel { model in
            for (index, scalar) in "VISIBLE".unicodeScalars.enumerated() {
                model.grid.setCell(Cell(codepoint: scalar.value, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: index)
            }
        }

        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        drainMainQueue(testCase: self)

        renderFrame(for: view)
        XCTAssertNotNil(view.currentDrawable)
        XCTAssertGreaterThan(view.drawableSize.width, 0)
        XCTAssertGreaterThan(view.drawableSize.height, 0)

        controller.setScrollOffset(1)
        drainMainQueue(testCase: self)
        renderFrame(for: view)
        XCTAssertNotNil(view.currentDrawable)
        XCTAssertGreaterThan(view.drawableSize.width, 0)
        XCTAssertGreaterThan(view.drawableSize.height, 0)
    }

    func testTerminalViewMetalDrawSurvivesScrollAndDisplayScaleTransitions() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 14,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        for rowIndex in 0..<48 {
            let row = ArraySlice("ROW\(rowIndex)".unicodeScalars.map {
                Cell(codepoint: $0.value, attributes: .default, width: 1, isWideContinuation: false)
            })
            controller.scrollback.appendRow(row, isWrapped: false)
        }

        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        drainMainQueue(testCase: self)

        for state in [(0, 1.0 as CGFloat), (8, 2.0), (16, 1.5), (24, 3.0), (4, 2.0)] {
            controller.setScrollOffset(state.0)
            window.testBackingScaleFactor = state.1
            view.viewDidChangeBackingProperties()
            renderFrame(for: view)

            XCTAssertNotNil(view.currentDrawable)
            XCTAssertEqual(view.renderer?.glyphAtlas.scaleFactor, state.1)
            XCTAssertEqual(view.drawableSize.width, view.bounds.width * state.1, accuracy: 1.0)
            XCTAssertEqual(view.drawableSize.height, view.bounds.height * state.1, accuracy: 1.0)
        }
    }

    func testTerminalViewResizeImmediatelyUpdatesDrawableSizeBeforeNextDraw() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let controller = TerminalController(
            rows: 8,
            cols: 20,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )

        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160), renderer: renderer)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.testBackingScaleFactor = 2.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.terminalController = controller
        window.makeKeyAndOrderFront(nil)
        drainMainQueue(testCase: self)

        renderFrame(for: view)
        XCTAssertEqual(view.drawableSize.width, 640, accuracy: 1.0)
        XCTAssertEqual(view.drawableSize.height, 320, accuracy: 1.0)

        view.setFrameSize(NSSize(width: 500, height: 260))

        XCTAssertEqual(view.drawableSize.width, 1000, accuracy: 1.0)
        XCTAssertEqual(view.drawableSize.height, 520, accuracy: 1.0)
    }

    func testSplitTerminalContainerBuildsGridWithOverlayAndControllers() throws {
        let renderer = try makeRendererOrSkip()
        let controllers = (0..<3).map { index in
            TerminalController(
                rows: 4,
                cols: 12,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: "/tmp/\(index)"
            )
        }
        let view = SplitTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), renderer: renderer, controllers: controllers)

        view.layoutSubtreeIfNeeded()

        let scrollViews = allSubviews(in: view).compactMap { $0 as? TerminalScrollView }
        XCTAssertEqual(scrollViews.count, 3)
        XCTAssertTrue(allSubviews(in: view).contains { String(describing: type(of: $0)) == "SplitRenderView" })
        XCTAssertEqual(view.activeController?.id, controllers.first?.id)
        XCTAssertTrue(scrollViews.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
        XCTAssertTrue(scrollViews.allSatisfy { $0.terminalView.renderingSuppressed })
        XCTAssertTrue(scrollViews.allSatisfy { $0.terminalView.drawableSize == .zero })
    }

    func testSplitTerminalContainerUpdateControllersRebuildsSubviewCount() throws {
        let renderer = try makeRendererOrSkip()
        let initial = (0..<2).map { index in
            TerminalController(
                rows: 4,
                cols: 12,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: "/tmp/a\(index)"
            )
        }
        let replacement = (0..<4).map { index in
            TerminalController(
                rows: 4,
                cols: 12,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: "/tmp/b\(index)"
            )
        }
        let view = SplitTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 500, height: 320), renderer: renderer, controllers: initial)

        view.updateControllers(replacement)
        view.layoutSubtreeIfNeeded()

        let scrollViews = allSubviews(in: view).compactMap { $0 as? TerminalScrollView }
        XCTAssertEqual(scrollViews.count, 4)
        XCTAssertEqual(view.activeController?.id, replacement.first?.id)
        XCTAssertTrue(scrollViews.allSatisfy { $0.terminalView.drawableSize == .zero })
    }

    func testTerminalViewSuppressedRenderingReleasesBuffersAndDrawableStorage() throws {
        let renderer = try makeRendererOrSkip()
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), renderer: renderer)

        view.syncScaleFactorIfNeeded()
        XCTAssertGreaterThan(view.drawableSize.width, 0)

        _ = renderer.reusableBuffer(
            for: view,
            slot: .overviewTextGlyph,
            vertices: Array(repeating: 1, count: 256)
        )
        XCTAssertNotNil(renderer.bufferLength(for: view, slot: .overviewTextGlyph))

        view.renderingSuppressed = true

        XCTAssertEqual(view.drawableSize, .zero)
        XCTAssertNil(renderer.bufferLength(for: view, slot: .overviewTextGlyph))
        XCTAssertTrue(view.isPaused)
        XCTAssertFalse(view.enableSetNeedsDisplay)

        view.renderingSuppressed = false

        XCTAssertGreaterThan(view.drawableSize.width, 0)
        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(view.enableSetNeedsDisplay)
    }

    func testTerminalViewIdlePurgeReleasesReusableBuffersAfterRenderedFrame() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let controller = TerminalController(
            rows: 6,
            cols: 24,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13,
            initialDirectory: "/tmp/idle-terminal"
        )
        controller.withModel { model in
            for (column, scalar) in "terminal idle purge".unicodeScalars.enumerated() {
                model.grid.setCell(Cell(codepoint: scalar.value, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: column)
            }
        }

        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), renderer: renderer)
        view.terminalController = controller
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        drainMainQueue(testCase: self)

        renderFrame(for: view)

        XCTAssertTrue(renderer.hasTerminalBuffers(for: view))
        XCTAssertGreaterThan(renderer.terminalScrollbackScratchRowCapacity(for: view), 0)
        XCTAssertGreaterThan(renderer.terminalSearchScratchRowCapacity(for: view), 0)

        view.debugReleaseIdleBuffersNow()

        XCTAssertFalse(renderer.hasTerminalBuffers(for: view))
        XCTAssertEqual(view.drawableSize, .zero)
        XCTAssertEqual(renderer.terminalScrollbackScratchRowCapacity(for: view), 0)
        XCTAssertEqual(renderer.terminalSearchScratchRowCapacity(for: view), 0)
        XCTAssertEqual(renderer.terminalScrollbackScratchBufferedCellCount(for: view), 0)

        view.setNeedsDisplay(view.bounds)

        XCTAssertGreaterThan(view.drawableSize.width, 0)
        XCTAssertGreaterThan(view.drawableSize.height, 0)
    }

    func testTerminalViewIdlePurgeKeepsDrawableForFocusedFirstResponder() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let controller = TerminalController(
            rows: 6,
            cols: 24,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13,
            initialDirectory: "/tmp/focused-terminal"
        )
        controller.withModel { model in
            for (column, scalar) in "focused idle".unicodeScalars.enumerated() {
                model.grid.setCell(Cell(codepoint: scalar.value, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: column)
            }
        }

        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), renderer: renderer)
        view.terminalController = controller
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        drainMainQueue(testCase: self)
        window.makeFirstResponder(view)
        drainMainQueue(testCase: self)
        view.syncScaleFactorIfNeeded()
        _ = renderer.reusableBuffer(
            for: view,
            slot: .overviewTextGlyph,
            vertices: Array(repeating: 1, count: 256)
        )

        XCTAssertNotNil(renderer.bufferLength(for: view, slot: .overviewTextGlyph))
        view.debugReleaseIdleBuffersNow()

        XCTAssertNotNil(renderer.bufferLength(for: view, slot: .overviewTextGlyph))
    }

    func testTerminalViewInactiveReleaseDropsDrawableAndBuffersImmediately() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let controller = TerminalController(
            rows: 6,
            cols: 24,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13,
            initialDirectory: "/tmp/inactive-terminal"
        )
        controller.withModel { model in
            for (column, scalar) in "inactive release".unicodeScalars.enumerated() {
                model.grid.setCell(Cell(codepoint: scalar.value, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: column)
            }
        }

        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), renderer: renderer)
        view.terminalController = controller
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        drainMainQueue(testCase: self)

        renderFrame(for: view)
        XCTAssertTrue(renderer.hasTerminalBuffers(for: view))
        XCTAssertGreaterThan(view.drawableSize.width, 0)
        XCTAssertGreaterThan(renderer.terminalScrollbackScratchRowCapacity(for: view), 0)
        XCTAssertGreaterThan(renderer.terminalSearchScratchRowCapacity(for: view), 0)

        view.releaseInactiveRenderingResourcesNow()

        XCTAssertFalse(renderer.hasTerminalBuffers(for: view))
        XCTAssertEqual(view.drawableSize, .zero)
        XCTAssertEqual(renderer.terminalScrollbackScratchRowCapacity(for: view), 0)
        XCTAssertEqual(renderer.terminalSearchScratchRowCapacity(for: view), 0)
        XCTAssertEqual(renderer.terminalScrollbackScratchBufferedCellCount(for: view), 0)

        view.setNeedsDisplay(view.bounds)
        XCTAssertGreaterThan(view.drawableSize.width, 0)
        XCTAssertGreaterThan(view.drawableSize.height, 0)
    }

    func testTerminalViewMemoryPressureCompactionReleasesReusableBuffersWithoutDiscardingVisibleDrawable() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let controller = TerminalController(
            rows: 6,
            cols: 24,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13,
            initialDirectory: "/tmp/memory-pressure"
        )
        controller.withModel { model in
            for (column, scalar) in "memory pressure".unicodeScalars.enumerated() {
                model.grid.setCell(Cell(codepoint: scalar.value, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: column)
            }
        }

        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), renderer: renderer)
        view.terminalController = controller
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        drainMainQueue(testCase: self)

        renderFrame(for: view)
        let originalDrawableSize = view.drawableSize
        XCTAssertTrue(renderer.hasTerminalBuffers(for: view))
        XCTAssertGreaterThan(originalDrawableSize.width, 0)

        view.compactForMemoryPressureNow()

        XCTAssertFalse(renderer.hasTerminalBuffers(for: view))
        XCTAssertEqual(view.drawableSize, originalDrawableSize)
    }

    func testSplitTerminalContainerFontChangeKeepsOverlayAndControllerCountStable() throws {
        let renderer = try makeRendererOrSkip()
        let controllers = (0..<3).map { index in
            TerminalController(
                rows: 4,
                cols: 12,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: "/tmp/font\(index)"
            )
        }
        let view = SplitTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 500, height: 320), renderer: renderer, controllers: controllers)

        view.fontSizeDidChange()
        view.updateMarkedTextForFontChange()
        view.layoutSubtreeIfNeeded()

        let scrollViews = allSubviews(in: view).compactMap { $0 as? TerminalScrollView }
        XCTAssertEqual(scrollViews.count, 3)
        XCTAssertTrue(allSubviews(in: view).contains { String(describing: type(of: $0)) == "SplitRenderView" })
    }

    func testSplitRenderViewTracksWindowBackingScaleAndKeepsDrawableAlive() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let controllers = (0..<2).map { index in
            let controller = TerminalController(
                rows: 4,
                cols: 12,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: "/tmp/render\(index)"
            )
            controller.withModel { model in
                for (column, scalar) in "CELL\(index)".unicodeScalars.enumerated() {
                    model.grid.setCell(Cell(codepoint: scalar.value, attributes: .default, width: 1, isWideContinuation: false), at: 0, col: column)
                }
            }
            return controller
        }
        let container = SplitTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), renderer: renderer, controllers: controllers)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(container)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        container.layoutSubtreeIfNeeded()
        drainMainQueue(testCase: self)

        guard let splitRenderView = allSubviews(in: container).first(where: { $0 is SplitRenderView }) as? SplitRenderView else {
            XCTFail("SplitRenderView missing")
            return
        }

        splitRenderView.viewDidMoveToWindow()
        XCTAssertEqual(splitRenderView.layer?.contentsScale, window.backingScaleFactor)
        renderFrame(for: splitRenderView)
        XCTAssertNotNil(splitRenderView.currentDrawable)
        XCTAssertGreaterThan(splitRenderView.drawableSize.width, 0)
        XCTAssertGreaterThan(splitRenderView.drawableSize.height, 0)
    }

    func testSplitRenderViewRespondsToSimulatedDisplayScaleChange() throws {
        let renderer = try makeRendererOrSkip()
        let splitRenderView = SplitRenderView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), renderer: renderer)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(splitRenderView)

        splitRenderView.viewDidMoveToWindow()
        XCTAssertEqual(splitRenderView.layer?.contentsScale, 1.0)

        window.testBackingScaleFactor = 3.0
        splitRenderView.viewDidChangeBackingProperties()

        XCTAssertEqual(splitRenderView.layer?.contentsScale, 3.0)
    }

    func testSplitRenderViewResizeImmediatelyUpdatesDrawableSizeBeforeNextDraw() throws {
        let renderer = try makeRendererOrSkip()
        let splitRenderView = SplitRenderView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), renderer: renderer)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320))
        window.testBackingScaleFactor = 2.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(splitRenderView)

        splitRenderView.viewDidMoveToWindow()
        XCTAssertEqual(splitRenderView.drawableSize.width, 840.0, accuracy: 0.5)
        XCTAssertEqual(splitRenderView.drawableSize.height, 520.0, accuracy: 0.5)

        splitRenderView.setFrameSize(NSSize(width: 500, height: 280))

        XCTAssertEqual(splitRenderView.drawableSize.width, 1000.0, accuracy: 0.5)
        XCTAssertEqual(splitRenderView.drawableSize.height, 560.0, accuracy: 0.5)
    }

    func testSplitRenderViewSyncScaleFactorIfNeededUpdatesDrawableSizeAndAtlasScale() throws {
        let renderer = try makeRendererOrSkip()
        let splitRenderView = SplitRenderView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), renderer: renderer)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(splitRenderView)

        splitRenderView.viewDidMoveToWindow()
        XCTAssertEqual(splitRenderView.layer?.contentsScale, 1.0)
        XCTAssertEqual(splitRenderView.drawableSize.width, 420.0, accuracy: 0.5)
        XCTAssertEqual(splitRenderView.drawableSize.height, 260.0, accuracy: 0.5)
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 1.0)

        window.testBackingScaleFactor = 2.0
        splitRenderView.syncScaleFactorIfNeeded()

        XCTAssertEqual(splitRenderView.layer?.contentsScale, 2.0)
        XCTAssertEqual(splitRenderView.drawableSize.width, 840.0, accuracy: 0.5)
        XCTAssertEqual(splitRenderView.drawableSize.height, 520.0, accuracy: 0.5)
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 2.0)
    }

    func testStatusBarButtonsExposeExpectedTooltips() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        let buttons = allSubviews(in: view).compactMap { $0 as? NSButton }

        XCTAssertEqual(buttons.first(where: { $0.title == "◀ Overview" })?.toolTip, "Back to Overview (Cmd+`)")
        XCTAssertEqual(buttons.first(where: { $0.title == "Edit Notes" })?.toolTip, "Edit Notes")
    }

    func testStatusBarNotesButtonMatchesSpecTitle() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        let buttons = allSubviews(in: view).compactMap { $0 as? NSButton }

        XCTAssertNotNil(buttons.first(where: { $0.title == "Edit Notes" }))
    }

    func testStatusBarMetricsRoundToNearestWholeValues() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        view.updateCpuUsage(percent: 12.6)
        view.updateMemoryUsage(bytes: 1_572_864) // 1.5 MB
        view.layoutSubtreeIfNeeded()

        let labels = allSubviews(in: view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(labels.contains("CPU: 12.6% | MEM: 2MB"))
    }

    func testStatusBarFormatsZeroMetricsWithoutPlaceholderSpacing() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        view.updateCpuUsage(percent: 0)
        view.updateMemoryUsage(bytes: 0)
        view.layoutSubtreeIfNeeded()

        let labels = allSubviews(in: view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(labels.contains("CPU: 0.0% | MEM: 0MB"))
    }

    func testSearchBarLayoutPlacesCountLabelOnRightEdge() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.layoutSubtreeIfNeeded()

        let searchField = allSubviews(in: view).compactMap { $0 as? NSSearchField }.first
        let countLabel = allSubviews(in: view)
            .compactMap { $0 as? NSTextField }
            .first(where: { !($0 is NSSearchField) })

        XCTAssertEqual(searchField?.frame.origin.x, 8)
        XCTAssertEqual(countLabel?.frame.origin.x, 228)
        XCTAssertEqual(countLabel?.frame.width, 64)
    }

    func testSearchBarZeroCountRendersPlainZero() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.updateCount(current: 1, total: 0)

        let countLabel = allSubviews(in: view)
            .compactMap { $0 as? NSTextField }
            .first(where: { !($0 is NSSearchField) })

        XCTAssertEqual(countLabel?.stringValue, "0")
    }

    func testSearchBarUpdateCountWithoutCurrentShowsTotalOnly() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.updateCount(current: 2, total: 5)
        view.updateCount(current: nil, total: 5)

        let countLabel = allSubviews(in: view)
            .compactMap { $0 as? NSTextField }
            .first(where: { !($0 is NSSearchField) })

        XCTAssertEqual(countLabel?.stringValue, "5")
    }

    func testSearchBarUpdateCountWithoutCurrentShowsSingleResultTotalOnly() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.updateCount(current: nil, total: 1)

        let countLabel = allSubviews(in: view)
            .compactMap { $0 as? NSTextField }
            .first(where: { !($0 is NSSearchField) })

        XCTAssertEqual(countLabel?.stringValue, "1")
    }

    func testSearchBarUpdateCountAllowsZeroBasedCurrentIndex() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.updateCount(current: 0, total: 5)

        let countLabel = allSubviews(in: view)
            .compactMap { $0 as? NSTextField }
            .first(where: { !($0 is NSSearchField) })

        XCTAssertEqual(countLabel?.stringValue, "0/5")
    }

    func testSearchBarUpdateCountAllowsZeroBasedSingleMatch() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.updateCount(current: 0, total: 1)

        let countLabel = allSubviews(in: view)
            .compactMap { $0 as? NSTextField }
            .first(where: { !($0 is NSSearchField) })

        XCTAssertEqual(countLabel?.stringValue, "0/1")
    }

    func testSearchBarUpdateCountClearsStaleCurrentWhenResultsDisappear() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.updateCount(current: 3, total: 9)
        view.updateCount(current: 3, total: 0)

        let countLabel = allSubviews(in: view)
            .compactMap { $0 as? NSTextField }
            .first(where: { !($0 is NSSearchField) })

        XCTAssertEqual(countLabel?.stringValue, "0")
    }

    func testSearchBarUpdateCountCanReturnFromZeroToNonzeroTotalOnly() {
        let view = SearchBarView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        view.updateCount(current: 3, total: 0)
        view.updateCount(current: nil, total: 7)

        let countLabel = allSubviews(in: view)
            .compactMap { $0 as? NSTextField }
            .first(where: { !($0 is NSSearchField) })

        XCTAssertEqual(countLabel?.stringValue, "7")
    }

    func testStatusBarKeepsNoteButtonAtLeftInsetWhenOverviewHidden() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        view.setBackButtonVisible(false)
        view.layoutSubtreeIfNeeded()

        let buttons = allSubviews(in: view).compactMap { $0 as? NSButton }
        let noteButton = buttons.first(where: { $0.title == "Edit Notes" })
        let overviewButton = buttons.first(where: { $0.title == "◀ Overview" })

        XCTAssertEqual(overviewButton?.isHidden, true)
        XCTAssertEqual(noteButton?.frame.origin.x, 12)
    }

    func testStatusBarKeepsNoteButtonVisibleWhenOverviewShown() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        view.setBackButtonVisible(true)
        view.layoutSubtreeIfNeeded()

        let buttons = allSubviews(in: view).compactMap { $0 as? NSButton }
        let noteButton = buttons.first(where: { $0.title == "Edit Notes" })
        let overviewButton = buttons.first(where: { $0.title == "◀ Overview" })

        XCTAssertEqual(overviewButton?.isHidden, false)
        XCTAssertEqual(noteButton?.isHidden, false)
        XCTAssertGreaterThan((noteButton?.frame.origin.x ?? 0), (overviewButton?.frame.maxX ?? 0))
    }

    func testStatusBarMetricsRemainRightAlignedWhenOverviewAppears() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        view.updateCpuUsage(percent: 12)
        view.updateMemoryUsage(bytes: 512 * 1024 * 1024)
        view.layoutSubtreeIfNeeded()

        let labelBefore = allSubviews(in: view)
            .compactMap { $0 as? NSTextField }
            .first(where: { $0.stringValue.contains("CPU:") })
        let maxXBefore = labelBefore?.frame.maxX

        view.setBackButtonVisible(true)
        view.layoutSubtreeIfNeeded()

        let labelAfter = allSubviews(in: view)
            .compactMap { $0 as? NSTextField }
            .first(where: { $0.stringValue.contains("CPU:") })

        XCTAssertEqual(maxXBefore, 388)
        XCTAssertEqual(labelAfter?.frame.maxX, 388)
    }

    func testStatusBarUpdatesSingleMetricWithoutLosingOtherValue() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        view.updateCpuUsage(percent: 19)
        view.updateMemoryUsage(bytes: 256 * 1024 * 1024)
        view.updateCpuUsage(percent: 21)
        view.layoutSubtreeIfNeeded()

        let labels = allSubviews(in: view).compactMap { $0 as? NSTextField }.map(\.stringValue)

        XCTAssertTrue(labels.contains("CPU: 21.0% | MEM: 256MB"))
    }

    func testStatusBarMemoryUpdateKeepsExistingCpuValue() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        view.updateCpuUsage(percent: 33)
        view.updateMemoryUsage(bytes: 128 * 1024 * 1024)
        view.updateMemoryUsage(bytes: 384 * 1024 * 1024)
        view.layoutSubtreeIfNeeded()

        let labels = allSubviews(in: view).compactMap { $0 as? NSTextField }.map(\.stringValue)

        XCTAssertTrue(labels.contains("CPU: 33.0% | MEM: 384MB"))
    }

    func testStatusBarRepeatedBackButtonVisibilityCallKeepsControlsVisible() {
        let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        let labels = allSubviews(in: view).compactMap { $0 as? NSTextField }
        let separator = labels.first(where: { $0.stringValue == "|" })
        let overview = allSubviews(in: view).compactMap { $0 as? NSButton }.first(where: { $0.title == "◀ Overview" })

        view.setBackButtonVisible(true)
        view.setBackButtonVisible(true)

        XCTAssertEqual(overview?.isHidden, false)
        XCTAssertEqual(separator?.isHidden, false)
    }

    func testMarkdownEditorMarksWindowTitleDirtyAfterEdit() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "seed",
            onSave: { _ in }
        )

        guard let window = controller.window,
              let textView = findSubview(in: window.contentView, matching: { $0 is NSTextView }) as? NSTextView else {
            XCTFail("Markdown editor hierarchy missing")
            return
        }

        XCTAssertEqual(window.title, "Notes")

        textView.insertText("!", replacementRange: textView.selectedRange())
        drainMainQueue(testCase: self)

        XCTAssertEqual(window.title, "* Notes")
    }

    func testMarkdownEditorCommandSInvokesSaveAndClearsDirtyMarker() throws {
        var savedText: String?
        let controller = MarkdownEditorWindowController(
            initialText: "seed",
            onSave: { savedText = $0 }
        )

        guard let window = controller.window,
              let textView = findSubview(in: window.contentView, matching: { $0 is NSTextView }) as? NSTextView else {
            XCTFail("Markdown editor hierarchy missing")
            return
        }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.insertText("!", replacementRange: textView.selectedRange())
        drainMainQueue(testCase: self)
        XCTAssertEqual(window.title, "* Notes")

        guard let saveEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "s",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: 1
        ) else {
            XCTFail("Failed to synthesize Cmd+S event")
            return
        }

        NSApp.sendEvent(saveEvent)
        drainMainQueue(testCase: self)

        XCTAssertEqual(savedText, "seed!")
        XCTAssertEqual(window.title, "Notes")
    }

    func testMarkdownEditorCommandSIgnoresCleanWindow() throws {
        var saveCount = 0
        let controller = MarkdownEditorWindowController(
            initialText: "seed",
            onSave: { _ in saveCount += 1 }
        )

        guard let window = controller.window,
              let textView = findSubview(in: window.contentView, matching: { $0 is NSTextView }) as? NSTextView else {
            XCTFail("Markdown editor hierarchy missing")
            return
        }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)

        guard let saveEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "s",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: 1
        ) else {
            XCTFail("Failed to synthesize Cmd+S event")
            return
        }

        NSApp.sendEvent(saveEvent)
        drainMainQueue(testCase: self)

        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(window.title, "Notes")
    }

    func testMarkdownEditorShowEditorWindowMakesTextViewFirstResponder() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "seed",
            onSave: { _ in }
        )

        guard let window = controller.window,
              let textView = findSubview(in: window.contentView, matching: { $0 is NSTextView }) as? NSTextView else {
            XCTFail("Markdown editor hierarchy missing")
            return
        }

        controller.showEditorWindow()
        drainMainQueue(testCase: self)

        XCTAssertTrue(window.firstResponder === textView)
    }

    func testMarkdownEditorWindowShellMatchesSpec() {
        let controller = MarkdownEditorWindowController(
            initialText: "",
            onSave: { _ in }
        )

        XCTAssertEqual(controller.window?.title, "Notes")
        XCTAssertEqual(controller.window?.minSize.width, 400)
        XCTAssertEqual(controller.window?.minSize.height, 300)
    }

    func testMarkdownEditorWindowSupportsExpectedWindowControls() {
        let controller = MarkdownEditorWindowController(
            initialText: "",
            onSave: { _ in }
        )
        let styleMask = controller.window?.styleMask ?? []

        XCTAssertTrue(styleMask.contains(.titled))
        XCTAssertTrue(styleMask.contains(.closable))
        XCTAssertTrue(styleMask.contains(.resizable))
        XCTAssertTrue(styleMask.contains(.miniaturizable))
    }

    func testMarkdownEditorWindowUsesDarkAppearanceAndPersistentWindowInstance() {
        let controller = MarkdownEditorWindowController(
            initialText: "",
            onSave: { _ in }
        )

        let window = controller.window
        guard let background = window?.backgroundColor.usingColorSpace(.deviceRGB) else {
            XCTFail("Markdown editor background color missing")
            return
        }

        XCTAssertEqual(window?.appearance?.name, .darkAqua)
        XCTAssertEqual(window?.isReleasedWhenClosed, false)
        XCTAssertEqual(Double(background.alphaComponent), 0.0, accuracy: 0.0001)
        XCTAssertFalse(window?.isOpaque ?? true)
    }

    func testMarkdownEditorUsesTransparentEditorBackgroundLikeIntegratedView() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "",
            onSave: { _ in }
        )

        let textView = try XCTUnwrap(findSubview(in: controller.window?.contentView) { $0 is NSTextView } as? NSTextView)
        let scrollView = try XCTUnwrap(findSubview(in: controller.window?.contentView) { $0 is NSScrollView } as? NSScrollView)

        guard let textBackground = textView.backgroundColor.usingColorSpace(.deviceRGB),
              let scrollBackground = scrollView.backgroundColor.usingColorSpace(.deviceRGB) else {
            XCTFail("Markdown editor backgrounds missing")
            return
        }

        XCTAssertEqual(Double(textBackground.alphaComponent), 0.0, accuracy: 0.0001)
        XCTAssertEqual(Double(scrollBackground.alphaComponent), 0.0, accuracy: 0.0001)
        XCTAssertFalse(textView.drawsBackground)
        XCTAssertFalse(scrollView.drawsBackground)
    }

    func testMarkdownEditorInstallsGlassBackgroundWhenAvailable() {
        let controller = MarkdownEditorWindowController(
            initialText: "",
            onSave: { _ in }
        )

        if #available(macOS 26.0, *) {
            XCTAssertNotNil(findSubview(in: controller.window?.contentView) { $0 is NSGlassEffectView })
        }
    }

    func testMarkdownEditorWindowStartsCleanWithoutDirtyMarker() {
        let controller = MarkdownEditorWindowController(
            initialText: "seed",
            onSave: { _ in }
        )

        XCTAssertEqual(controller.window?.title, "Notes")
        guard let window = controller.window else {
            XCTFail("Markdown editor window missing")
            return
        }
        XCTAssertTrue(controller.windowShouldClose(window))
    }

    func testMarkdownEditorAllowsCleanWindowToCloseWithoutPrompt() {
        let controller = MarkdownEditorWindowController(
            initialText: "",
            onSave: { _ in }
        )

        guard let window = controller.window else {
            XCTFail("Markdown editor window missing")
            return
        }

        XCTAssertTrue(controller.windowShouldClose(window))
    }

    func testMarkdownEditorInvokesOnCloseCallback() {
        let controller = MarkdownEditorWindowController(
            initialText: "",
            onSave: { _ in }
        )
        var didClose = false
        controller.onClose = { didClose = true }

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertTrue(didClose)
    }

    func testMarkdownEditorDirtyCloseSaveResponseSavesAndAllowsClose() throws {
        let saveSpy = SaveSpy()
        let controller = MarkdownEditorWindowController(initialText: "draft", onSave: saveSpy.record(_:))
        let textView = try XCTUnwrap(findSubview(in: controller.window?.contentView) { $0 is NSTextView } as? NSTextView)
        textView.string = "changed"
        textView.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: textView))

        try withMockedAlertResponse(.alertFirstButtonReturn) {
            let shouldClose = controller.windowShouldClose(try XCTUnwrap(controller.window))
            XCTAssertTrue(shouldClose)
            XCTAssertEqual(saveSpy.savedTexts, ["changed"])
            XCTAssertEqual(AlertRunModalSwizzler.capturedAlert?.messageText, "Unsaved Changes")
            XCTAssertEqual(AlertRunModalSwizzler.capturedAlert?.buttons.map(\.title), ["Save", "Don't Save", "Cancel"])
            XCTAssertEqual(controller.window?.title, "Notes")
        }
    }

    func testMarkdownEditorDirtyCloseDontSaveResponseAllowsCloseWithoutSaving() throws {
        let saveSpy = SaveSpy()
        let controller = MarkdownEditorWindowController(initialText: "draft", onSave: saveSpy.record(_:))
        let textView = try XCTUnwrap(findSubview(in: controller.window?.contentView) { $0 is NSTextView } as? NSTextView)
        textView.string = "changed"
        textView.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: textView))

        try withMockedAlertResponse(.alertSecondButtonReturn) {
            let shouldClose = controller.windowShouldClose(try XCTUnwrap(controller.window))
            XCTAssertTrue(shouldClose)
            XCTAssertTrue(saveSpy.savedTexts.isEmpty)
            XCTAssertEqual(controller.window?.title, "* Notes")
        }
    }

    func testMarkdownEditorDirtyCloseCancelResponseKeepsWindowOpen() throws {
        let saveSpy = SaveSpy()
        let controller = MarkdownEditorWindowController(initialText: "draft", onSave: saveSpy.record(_:))
        let textView = try XCTUnwrap(findSubview(in: controller.window?.contentView) { $0 is NSTextView } as? NSTextView)
        textView.string = "changed"
        textView.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: textView))

        try withMockedAlertResponse(.alertThirdButtonReturn) {
            let shouldClose = controller.windowShouldClose(try XCTUnwrap(controller.window))
            XCTAssertFalse(shouldClose)
            XCTAssertTrue(saveSpy.savedTexts.isEmpty)
            XCTAssertEqual(controller.window?.title, "* Notes")
        }
    }

    func testMarkdownEditorFailedSaveKeepsDirtyMarkerAndPreventsClose() throws {
        let controller = MarkdownEditorWindowController(initialText: "draft") { _ in
            throw SaveFailure.expected
        }
        let textView = try XCTUnwrap(findSubview(in: controller.window?.contentView) { $0 is NSTextView } as? NSTextView)
        textView.string = "changed"
        textView.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: textView))

        try withMockedAlertResponse(.alertFirstButtonReturn) {
            let shouldClose = controller.windowShouldClose(try XCTUnwrap(controller.window))
            XCTAssertFalse(shouldClose)
            XCTAssertEqual(controller.window?.title, "* Notes")
            XCTAssertNotNil(AlertRunModalSwizzler.capturedAlert)
        }
    }

    func testIntegratedViewCommandASelectsSingleTerminalViaCallback() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let terminal = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), renderer: renderer, manager: manager)
        var selectedID: UUID?
        view.onSelectTerminal = { selectedID = $0.id }

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!

        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(selectedID, terminal.id)
    }

    func testIntegratedViewCommandAUsesMultiSelectForMultipleTerminals() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let first = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        let second = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), renderer: renderer, manager: manager)
        var selectedIDs: [UUID] = []
        view.onMultiSelect = { selectedIDs = $0.map(\.id) }

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!

        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(Set(selectedIDs), Set([first.id, second.id]))
    }

    func testIntegratedViewCommandAUsesMultiSelectAfterDisplayScaleChange() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let first = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        let second = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.viewDidMoveToWindow()
        window.testBackingScaleFactor = 2.0
        view.viewDidChangeBackingProperties()

        var selectedIDs: [UUID] = []
        view.onMultiSelect = { selectedIDs = $0.map(\.id) }
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!

        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 2.0)
        XCTAssertEqual(Set(selectedIDs), Set([first.id, second.id]))
    }

    func testIntegratedViewCommandASelectsSingleTerminalAfterDisplayScaleChange() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let terminal = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        view.viewDidMoveToWindow()
        window.testBackingScaleFactor = 2.0
        view.viewDidChangeBackingProperties()

        var selectedID: UUID?
        view.onSelectTerminal = { selectedID = $0.id }
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!

        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 2.0)
        XCTAssertEqual(selectedID, terminal.id)
    }

    func testNewTerminalShortcutContextUsesFocusedControllerWorkspaceAndAppendsNewTerminalToSplit() {
        let focused = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13,
            workspaceName: "Alpha"
        )
        let newController = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13,
            workspaceName: "Alpha"
        )

        let context = AppDelegate.newTerminalShortcutContext(
            focusedController: focused,
            splitControllers: []
        )

        XCTAssertEqual(context?.workspaceName, "Alpha")
        XCTAssertEqual(context?.displayedControllers.map(\.id) ?? [], [focused.id])
        XCTAssertEqual((context?.displayedControllers.map(\.id) ?? []) + [newController.id], [focused.id, newController.id])
    }

    func testNewTerminalShortcutContextUsesLastDisplayedSplitControllerWorkspaceAndAppendsNewTerminal() {
        let first = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13,
            workspaceName: "Alpha"
        )
        let last = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13,
            workspaceName: "Beta"
        )
        let newController = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13,
            workspaceName: "Beta"
        )

        let context = AppDelegate.newTerminalShortcutContext(
            focusedController: nil,
            splitControllers: [first, last]
        )

        XCTAssertEqual(context?.workspaceName, "Beta")
        XCTAssertEqual(context?.displayedControllers.map(\.id) ?? [], [first.id, last.id])
        XCTAssertEqual((context?.displayedControllers.map(\.id) ?? []) + [newController.id], [first.id, last.id, newController.id])
    }

    func testIntegratedViewSyncScaleFactorUpdatesDrawableSizeAndAtlasScale() throws {
        guard let renderer = MetalRenderer(scaleFactor: 1.0) else {
            throw XCTSkip("Metal unavailable")
        }
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), renderer: renderer, manager: manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)

        view.syncScaleFactorIfNeeded()

        let scale = window.backingScaleFactor
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, scale)
        XCTAssertEqual(Double(view.drawableSize.width), Double(view.bounds.width * scale), accuracy: 1.0)
        XCTAssertEqual(Double(view.drawableSize.height), Double(view.bounds.height * scale), accuracy: 1.0)
    }

    func testIntegratedViewUsesDemandDrivenRenderingWhenIdleAndUsesPulseTimerForActiveOutput() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let controller = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), renderer: renderer, manager: manager)

        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(view.enableSetNeedsDisplay)
        XCTAssertFalse(view.debugHasOutputPulseTimer)
        XCTAssertFalse(view.debugHasOutputContentRedrawTimer)

        XCTAssertTrue(view.setTerminalOutputActive(controller.id, isActive: true))

        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(view.enableSetNeedsDisplay)
        XCTAssertTrue(view.debugHasOutputPulseTimer)
        XCTAssertFalse(view.debugHasOutputContentRedrawTimer)

        XCTAssertTrue(view.setTerminalOutputActive(controller.id, isActive: false))

        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(view.enableSetNeedsDisplay)
        XCTAssertFalse(view.debugHasOutputPulseTimer)
        XCTAssertFalse(view.debugHasOutputContentRedrawTimer)
    }

    func testIntegratedViewRepeatedOutputActivityRequestsDisplayWithoutContinuousRenderLoop() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let controller = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), renderer: renderer, manager: manager)

        view.noteTerminalOutputActivity(controller.id)
        XCTAssertEqual(view.debugOverviewOutputDisplayRequestCount, 1)
        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(view.enableSetNeedsDisplay)
        XCTAssertTrue(view.debugHasOutputPulseTimer)
        XCTAssertFalse(view.debugHasOutputContentRedrawTimer)

        view.noteTerminalOutputActivity(controller.id)
        XCTAssertEqual(view.debugOverviewOutputDisplayRequestCount, 1)
        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(view.enableSetNeedsDisplay)
        XCTAssertTrue(view.debugHasOutputPulseTimer)
        XCTAssertTrue(view.debugHasOutputContentRedrawTimer)
    }

    func testIntegratedViewContentActivityRequestsDisplayWithoutMarkingTerminalActive() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let controller = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), renderer: renderer, manager: manager)

        view.noteTerminalContentActivity(controller.id)

        XCTAssertEqual(view.debugOverviewOutputDisplayRequestCount, 1)
        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(view.enableSetNeedsDisplay)
        XCTAssertFalse(view.debugHasOutputPulseTimer)
        XCTAssertFalse(view.debugHasOutputContentRedrawTimer)
        XCTAssertFalse(view.activeOutputTerminals.contains(controller.id))
    }

    func testIntegratedViewContentActivityInvalidatesThumbnailSurfaceCacheEntry() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let controller = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        renderFrame(for: view)
        view.debugSeedThumbnailSurfaceCacheForTesting(controllerID: controller.id)
        XCTAssertTrue(view.debugHasThumbnailSurfaceCacheEntry(for: controller.id))

        view.noteTerminalContentActivity(controller.id)

        XCTAssertFalse(view.debugHasThumbnailSurfaceCacheEntry(for: controller.id))
    }

    func testIntegratedViewOffscreenThumbnailSurfaceRendersVisibleTerminalContentForEachController() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let left = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )
        let right = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        func seedVisibleText(_ text: String, row: Int, controller: TerminalController) {
            for (column, scalar) in text.unicodeScalars.enumerated() {
                controller.model.grid.setCell(
                    Cell(codepoint: scalar.value, attributes: .default, width: 1, isWideContinuation: false),
                    at: row,
                    col: column
                )
            }
        }

        seedVisibleText("LEFT TERMINAL CONTENT", row: 1, controller: left)
        seedVisibleText("ROW TWO OF LEFT", row: 2, controller: left)
        seedVisibleText("RIGHT TERMINAL CONTENT", row: 1, controller: right)
        seedVisibleText("TOP TOP TOP TOP TOP", row: 2, controller: right)
        seedVisibleText("CPU 99.9 MEM 10.0", row: 3, controller: right)
        left.model.grid.setCell(
            Cell(
                codepoint: Unicode.Scalar("X").value,
                attributes: CellAttributes(
                    foreground: .rgb(255, 255, 255),
                    background: .rgb(255, 0, 0),
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
            ),
            at: 0,
            col: 0
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 960, height: 480), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 480))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        view.noteTerminalContentActivity(left.id)
        view.noteTerminalContentActivity(right.id)
        renderFrame(for: view)

        if let leftLayout = view.debugThumbnailLayout(for: left.id) {
            print("left thumbnail size:", leftLayout)
        }
        if let rightLayout = view.debugThumbnailLayout(for: right.id) {
            print("right thumbnail size:", rightLayout)
        }
        XCTAssertGreaterThan(view.debugThumbnailVertexCounts(for: left.id)?.glyph ?? 0, 0)
        XCTAssertGreaterThan(view.debugThumbnailVertexCounts(for: right.id)?.glyph ?? 0, 0)
        XCTAssertGreaterThan(view.debugThumbnailVertexCounts(for: left.id)?.background ?? 0, 0)
        print("glyph pipeline exists:", renderer.glyphPipeline != nil)
        print("lowdpi pipeline exists:", renderer.lowDPIGlyphPipeline != nil)
        print("sampler exists:", renderer.samplerState != nil)
        print("thumbnail sampler exists:", renderer.thumbnailSamplerState != nil)
        print("atlas texture:", String(describing: renderer.glyphAtlas.texturePixelSize))
        print("atlas glyph count:", renderer.glyphAtlas.glyphCache.count)
        if let atlas = renderer.glyphAtlas.texture {
            let bytesPerRow = atlas.width
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * atlas.height)
            atlas.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, atlas.width, atlas.height), mipmapLevel: 0)
            print("atlas max coverage:", bytes.max() ?? 0)
        }
        if let leftBounds = view.debugThumbnailGlyphBounds(for: left.id) {
            print("left glyph bounds:", leftBounds)
        }
        if let leftBgBounds = view.debugThumbnailBackgroundBounds(for: left.id) {
            print("left background bounds:", leftBgBounds)
        }
        if let rightBounds = view.debugThumbnailGlyphBounds(for: right.id) {
            print("right glyph bounds:", rightBounds)
        }
        XCTAssertGreaterThan(view.debugRenderedThumbnailMaximumAlpha(for: left.id) ?? 0, 0)
        XCTAssertGreaterThan(view.debugRenderedThumbnailMaximumAlpha(for: right.id) ?? 0, 0)
        XCTAssertGreaterThan(view.debugCachedThumbnailSurfaceMaximumAlpha(for: left.id) ?? 0, 0)
        XCTAssertGreaterThan(view.debugCachedThumbnailSurfaceMaximumAlpha(for: right.id) ?? 0, 0)
    }

    func testMetalRendererCanRenderOpaqueQuadIntoOffscreenTexture() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let size = NSSize(width: 64, height: 64)
        let scaleFactor: Float = 2.0
        let width = Int(size.width * CGFloat(scaleFactor))
        let height = Int(size.height * CGFloat(scaleFactor))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalRenderer.renderTargetPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let commandBuffer = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))

        var vertices: [Float] = []
        renderer.addQuadPublic(
            to: &vertices,
            x: 10, y: 10, w: 40, h: 40,
            tx: 0, ty: 0, tw: 0, th: 0,
            fg: (1, 0, 0, 1),
            bg: (1, 0, 0, 1)
        )
        let buffer = try XCTUnwrap(renderer.makeTemporaryBuffer(vertices: vertices))
        var uniforms = MetalRenderer.MetalUniforms(
            viewportSize: SIMD2<Float>(Float(width), Float(height)),
            cursorOpacity: 0,
            time: 0
        )
        encoder.setRenderPipelineState(try XCTUnwrap(renderer.bgPipeline))
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalRenderer.MetalUniforms>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 12)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var maximumAlpha: UInt8 = 0
        var index = 3
        while index < bytes.count {
            maximumAlpha = max(maximumAlpha, bytes[index])
            index += 4
        }
        XCTAssertGreaterThan(maximumAlpha, 0)
    }

    func testIntegratedViewFinalCompositeShowsVisiblePixelsInsideEachThumbnailBody() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let left = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )
        let right = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        func seedVisibleText(_ text: String, row: Int, controller: TerminalController) {
            for (column, scalar) in text.unicodeScalars.enumerated() {
                controller.model.grid.setCell(
                    Cell(codepoint: scalar.value, attributes: .default, width: 1, isWideContinuation: false),
                    at: row,
                    col: column
                )
            }
        }

        seedVisibleText("LEFT BODY", row: 1, controller: left)
        seedVisibleText("RIGHT BODY", row: 1, controller: right)
        seedVisibleText("RUNNING TOP", row: 2, controller: right)
        seedVisibleText("UPDATING VIEWPORT", row: 3, controller: right)

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 960, height: 480), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 480))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        view.noteTerminalContentActivity(left.id)
        view.noteTerminalContentActivity(right.id)
        renderFrame(for: view)

        let workspace = try XCTUnwrap(reflectedWorkspaceLayouts(from: view).first)
        let leftFrame = try XCTUnwrap(workspace.terminals.first(where: { $0.controllerID == left.id })?.thumbnail)
        let rightFrame = try XCTUnwrap(workspace.terminals.first(where: { $0.controllerID == right.id })?.thumbnail)
        let bodyInset = CGFloat(12)
        let leftBody = leftFrame.insetBy(dx: bodyInset, dy: bodyInset)
        let rightBody = rightFrame.insetBy(dx: bodyInset, dy: bodyInset)

        XCTAssertGreaterThan(view.debugRenderedOverviewOpaquePixelCount(in: leftBody) ?? 0, 32)
        XCTAssertGreaterThan(view.debugRenderedOverviewOpaquePixelCount(in: rightBody) ?? 0, 32)
    }

    func testIntegratedViewLivePTYOutputInvalidatesAndRebuildsThumbnailSurface() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let config = PtermConfig(
            term: PtermConfig.default.term,
            textEncoding: PtermConfig.default.textEncoding,
            shellLaunch: PtermConfig.default.shellLaunch,
            textInteraction: PtermConfig.default.textInteraction,
            fontName: PtermConfig.default.fontName,
            fontSize: PtermConfig.default.fontSize,
            terminalAppearance: TerminalAppearanceConfiguration(
                foreground: PtermConfig.default.terminalAppearance.foreground,
                background: PtermConfig.default.terminalAppearance.background,
                backgroundOpacity: 1.0
            ),
            memoryMax: PtermConfig.default.memoryMax,
            memoryInitial: PtermConfig.default.memoryInitial,
            sessionScrollBufferPersistence: PtermConfig.default.sessionScrollBufferPersistence,
            audit: PtermConfig.default.audit,
            security: PtermConfig.default.security,
            shortcuts: PtermConfig.default.shortcuts,
            workspaces: PtermConfig.default.workspaces
        )
        let manager = TerminalManager(rows: 24, cols: 80, config: config)
        defer { manager.stopAll(waitForExit: true) }

        let left = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )
        let right = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 960, height: 480), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 480))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        renderFrame(for: view)
        let initialRightVersion = right.thumbnailContentVersion

        right.sendInput("printf 'LIVE THUMBNAIL BODY\\nSECOND LINE\\n'\n")
        let outputExpectation = expectation(description: "live output reaches controller")
        let deadline = Date().addingTimeInterval(5.0)
        func pollOutput() {
            if right.allText().contains("LIVE THUMBNAIL BODY") {
                outputExpectation.fulfill()
                return
            }
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: pollOutput)
            }
        }
        DispatchQueue.main.async(execute: pollOutput)
        wait(for: [outputExpectation], timeout: 6.0)

        let redrawExpectation = expectation(description: "overview redraw requested for live output")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            redrawExpectation.fulfill()
        }
        wait(for: [redrawExpectation], timeout: 1.0)

        view.noteTerminalContentActivity(right.id)
        view.debugEnsureLayoutCache()

        XCTAssertGreaterThan(right.thumbnailContentVersion, initialRightVersion)
        XCTAssertGreaterThan(view.debugRenderedThumbnailMaximumAlpha(for: right.id) ?? 0, 0)

        let workspace = try XCTUnwrap(reflectedWorkspaceLayouts(from: view).first)
        let rightFrame = try XCTUnwrap(workspace.terminals.first(where: { $0.controllerID == right.id })?.thumbnail)
        let rightBody = rightFrame.insetBy(dx: 12, dy: 12)
        XCTAssertGreaterThan(view.debugRenderedOverviewOpaquePixelCount(in: rightBody) ?? 0, 32)
    }

    func testIntegratedViewAlternateScreenThumbnailRendersVisibleBodyPixels() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let config = PtermConfig(
            term: PtermConfig.default.term,
            textEncoding: PtermConfig.default.textEncoding,
            shellLaunch: PtermConfig.default.shellLaunch,
            textInteraction: PtermConfig.default.textInteraction,
            fontName: PtermConfig.default.fontName,
            fontSize: PtermConfig.default.fontSize,
            terminalAppearance: TerminalAppearanceConfiguration(
                foreground: PtermConfig.default.terminalAppearance.foreground,
                background: PtermConfig.default.terminalAppearance.background,
                backgroundOpacity: 1.0
            ),
            memoryMax: PtermConfig.default.memoryMax,
            memoryInitial: PtermConfig.default.memoryInitial,
            sessionScrollBufferPersistence: PtermConfig.default.sessionScrollBufferPersistence,
            audit: PtermConfig.default.audit,
            security: PtermConfig.default.security,
            shortcuts: PtermConfig.default.shortcuts,
            workspaces: PtermConfig.default.workspaces
        )
        let manager = TerminalManager(rows: 24, cols: 80, config: config)
        defer { manager.stopAll(waitForExit: true) }

        let left = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )
        let right = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 960, height: 480), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 480))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        renderFrame(for: view)

        right.sendInput("printf '\\033[?1049h\\033[H\\033[2JALT BODY\\033[2;1HSECOND LINE\\n'\n")
        let outputExpectation = expectation(description: "alternate screen output reaches controller")
        let deadline = Date().addingTimeInterval(5.0)
        func pollOutput() {
            if right.allText().contains("ALT BODY") {
                outputExpectation.fulfill()
                return
            }
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: pollOutput)
            }
        }
        DispatchQueue.main.async(execute: pollOutput)
        wait(for: [outputExpectation], timeout: 6.0)

        view.noteTerminalContentActivity(left.id)
        view.noteTerminalContentActivity(right.id)
        renderFrame(for: view)

        XCTAssertGreaterThan(view.debugRenderedThumbnailMaximumAlpha(for: right.id) ?? 0, 0)
        XCTAssertGreaterThan(view.debugRenderedThumbnailOpaquePixelCount(for: right.id) ?? 0, 32)

        let workspace = try XCTUnwrap(reflectedWorkspaceLayouts(from: view).first)
        let rightFrame = try XCTUnwrap(workspace.terminals.first(where: { $0.controllerID == right.id })?.thumbnail)
        let rightBody = rightFrame.insetBy(dx: 12, dy: 12)
        XCTAssertGreaterThan(view.debugRenderedOverviewOpaquePixelCount(in: rightBody) ?? 0, 32)
    }

    func testIntegratedViewOutputRedrawIntervalScalesWithVisibleTerminalCount() {
        XCTAssertEqual(IntegratedView.effectiveOutputContentRedrawInterval(visibleTerminalCount: 0), 0.25, accuracy: 0.0001)
        XCTAssertEqual(IntegratedView.effectiveOutputContentRedrawInterval(visibleTerminalCount: 1), 0.25, accuracy: 0.0001)
        XCTAssertEqual(IntegratedView.effectiveOutputContentRedrawInterval(visibleTerminalCount: 2), 0.40, accuracy: 0.0001)
        XCTAssertEqual(IntegratedView.effectiveOutputContentRedrawInterval(visibleTerminalCount: 4), 0.70, accuracy: 0.0001)
        XCTAssertEqual(IntegratedView.effectiveOutputContentRedrawInterval(visibleTerminalCount: 8), 1.0, accuracy: 0.0001)
        XCTAssertEqual(IntegratedView.effectiveOutputContentRedrawInterval(visibleTerminalCount: 32), 1.0, accuracy: 0.0001)
    }

    func testIntegratedViewVerticallyCenteredTextOriginCentersGlyphBoundsInsideTitleBar() {
        let frame = NSRect(x: 10, y: 20, width: 200, height: 24)
        let originY = IntegratedView.verticallyCenteredTextOriginY(
            frame: frame,
            scaleFactor: 2.0,
            contentMinY: 3.0,
            contentHeight: 12.0
        )

        let renderedMinY = originY + 3.0
        let renderedMaxY = renderedMinY + 12.0
        let frameMinY = Float(frame.minY) * 2.0
        let frameMaxY = Float(frame.maxY) * 2.0

        XCTAssertEqual((renderedMinY + renderedMaxY) / 2, (frameMinY + frameMaxY) / 2, accuracy: 0.001)
    }

    func testIntegratedViewDeinitReleasesRendererBuffers() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        weak var weakView: IntegratedView?

        XCTAssertEqual(renderer.activeViewBufferCount, 0)

        autoreleasepool {
            let manager = TerminalManager(rows: 24, cols: 80, config: .default)
            defer { manager.stopAll(waitForExit: true) }
            _ = try? manager.addTerminal(
                initialDirectory: NSTemporaryDirectory(),
                workspaceName: "WS",
                fontName: renderer.glyphAtlas.fontName,
                fontSize: Double(renderer.glyphAtlas.fontSize)
            )

            let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
            let contentView = NSView(frame: window.frame)
            window.contentView = contentView

            do {
                let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
                weakView = view
                contentView.addSubview(view)
                let overlay = ScrollbarOverlayView(frame: view.frame)
                overlay.documentView = ScrollDocumentView(frame: view.bounds)
                overlay.contentView.postsBoundsChangedNotifications = true
                view.companionScrollView = overlay

                renderFrame(for: view)
                XCTAssertGreaterThan(renderer.activeViewBufferCount, 0)
            }

            contentView.subviews.forEach { $0.removeFromSuperview() }
        }

        drainMainQueue(testCase: self)
        XCTAssertNil(weakView)
        XCTAssertEqual(renderer.activeViewBufferCount, 0)
    }

    func testIntegratedViewCachesOnlyVisibleWorkspaceLayoutsForDrawing() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        for index in 0..<18 {
            _ = try manager.addTerminal(
                initialDirectory: NSTemporaryDirectory(),
                workspaceName: "WS-\(index)",
                fontName: renderer.glyphAtlas.fontName,
                fontSize: Double(renderer.glyphAtlas.fontSize)
            )
        }

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        renderFrame(for: view)

        let allLayouts = reflectedWorkspaceLayouts(from: view)
        let visibleLayouts = reflectedVisibleWorkspaceLayouts(from: view)
        XCTAssertGreaterThan(allLayouts.count, visibleLayouts.count)
        XCTAssertTrue(visibleLayouts.allSatisfy { $0.frame.intersects(view.bounds) })
    }

    func testIntegratedViewThumbnailSurfaceRenderingDoesNotUseReusablePerThumbnailBufferSlot() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        _ = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        renderFrame(for: view)

        XCTAssertNil(renderer.bufferLength(for: view, slot: .overviewThumbnailSurface))
    }

    func testIntegratedViewPrunesOversizedTextVertexCache() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)

        _ = renderer.reusableBuffer(
            for: view,
            slot: .overviewTextGlyph,
            vertices: Array(repeating: 1, count: 4_096)
        )
        XCTAssertNotNil(renderer.bufferLength(for: view, slot: .overviewTextGlyph))

        view.debugPrimeTextVertexCache(texts: (0..<300).map { "Label-\($0)" })
        XCTAssertGreaterThan(view.cachedTextVertexCount, 0)

        view.terminalListDidChange()

        XCTAssertLessThanOrEqual(view.cachedTextVertexCount, 256)
        XCTAssertNil(renderer.bufferLength(for: view, slot: .overviewTextGlyph))
    }

    func testIntegratedViewPrunesOversizedTextVertexCacheByByteBudget() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)

        _ = renderer.reusableBuffer(
            for: view,
            slot: .overviewTextGlyph,
            vertices: Array(repeating: 1, count: 4_096)
        )
        XCTAssertNotNil(renderer.bufferLength(for: view, slot: .overviewTextGlyph))

        view.debugInsertOversizedTextVertexCacheEntry(text: "huge-1", floatCount: 400_000)
        view.debugInsertOversizedTextVertexCacheEntry(text: "huge-2", floatCount: 400_000)
        let softByteLimit = IntegratedView.effectiveTextVertexSoftByteLimit(visibleTerminalCount: 0)
        XCTAssertGreaterThan(view.cachedTextVertexBytes, softByteLimit)

        view.terminalListDidChange()

        XCTAssertLessThanOrEqual(view.cachedTextVertexBytes, softByteLimit)
        XCTAssertNil(renderer.bufferLength(for: view, slot: .overviewTextGlyph))
    }

    func testIntegratedViewPrunesThumbnailVertexCacheTowardVisibleTerminals() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        for index in 0..<80 {
            _ = try manager.addTerminal(
                initialDirectory: NSTemporaryDirectory(),
                workspaceName: "WS-\(index)",
                fontName: renderer.glyphAtlas.fontName,
                fontSize: Double(renderer.glyphAtlas.fontSize)
            )
        }

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        renderFrame(for: view)
        let visibleTerminalCount = reflectedVisibleWorkspaceLayouts(from: view).flatMap(\.terminals).count

        _ = renderer.reusableBuffer(
            for: view,
            slot: .overviewThumbnailGlyph,
            vertices: Array(repeating: 1, count: 4_096)
        )
        XCTAssertNotNil(renderer.bufferLength(for: view, slot: .overviewThumbnailGlyph))

        view.debugPrimeThumbnailVertexCache(scaleFactor: 2.25)
        let primedCount = view.cachedThumbnailVertexCount
        XCTAssertGreaterThan(primedCount, 0)

        view.terminalListDidChange()

        XCTAssertLessThanOrEqual(view.cachedThumbnailVertexCount, primedCount)
        XCTAssertLessThanOrEqual(
            view.cachedThumbnailVertexCount,
            IntegratedView.effectiveThumbnailVertexSoftLimit(preferredTerminalCount: visibleTerminalCount)
        )
    }

    func testIntegratedViewPrunesThumbnailVertexCacheByByteBudget() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        for index in 0..<40 {
            _ = try manager.addTerminal(
                initialDirectory: NSTemporaryDirectory(),
                workspaceName: "WS-\(index)",
                fontName: renderer.glyphAtlas.fontName,
                fontSize: Double(renderer.glyphAtlas.fontSize)
            )
        }

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        renderFrame(for: view)

        _ = renderer.reusableBuffer(
            for: view,
            slot: .overviewThumbnailGlyph,
            vertices: Array(repeating: 1, count: 4_096)
        )
        XCTAssertNotNil(renderer.bufferLength(for: view, slot: .overviewThumbnailGlyph))

        view.debugInsertOversizedThumbnailVertexCacheEntries(floatCountPerEntry: 120_000)
        let softByteLimit = IntegratedView.effectiveThumbnailVertexSoftByteLimit(
            preferredTerminalCount: reflectedVisibleWorkspaceLayouts(from: view).flatMap(\.terminals).count
        )
        XCTAssertGreaterThan(view.cachedThumbnailVertexBytes, softByteLimit)

        view.terminalListDidChange()

        XCTAssertLessThanOrEqual(view.cachedThumbnailVertexBytes, softByteLimit)
        XCTAssertNil(renderer.bufferLength(for: view, slot: .overviewThumbnailGlyph))
    }

    func testIntegratedViewDynamicTextVertexByteBudgetScalesWithVisibleTerminalCount() {
        XCTAssertEqual(IntegratedView.effectiveTextVertexSoftByteLimit(visibleTerminalCount: 0), 256 * 1024)
        XCTAssertEqual(IntegratedView.effectiveTextVertexSoftByteLimit(visibleTerminalCount: 2), 256 * 1024)
        XCTAssertEqual(IntegratedView.effectiveTextVertexSoftByteLimit(visibleTerminalCount: 16), 512 * 1024)
        XCTAssertEqual(IntegratedView.effectiveTextVertexSoftByteLimit(visibleTerminalCount: 64), 2 * 1024 * 1024)
        XCTAssertEqual(IntegratedView.effectiveTextVertexSoftByteLimit(visibleTerminalCount: 256), 2 * 1024 * 1024)
    }

    func testIntegratedViewTransientTextRenderingDoesNotPopulateTextVertexCache() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)

        view.debugPrimeTextVertexCache(texts: ["Stable"])
        let cachedCountBefore = view.cachedTextVertexCount
        let cachedBytesBefore = view.cachedTextVertexBytes

        let transientVertexCount = view.debugAppendTransientTextVertices(text: "CPU: 17.3%")

        XCTAssertGreaterThan(transientVertexCount, 0)
        XCTAssertEqual(view.cachedTextVertexCount, cachedCountBefore)
        XCTAssertEqual(view.cachedTextVertexBytes, cachedBytesBefore)
    }

    func testIntegratedViewCachedTextVerticesDropMostReserveCapacitySlack() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)

        view.debugPrimeTextVertexCache(texts: ["A reasonably long cacheable title string"])

        XCTAssertGreaterThan(view.cachedTextVertexBytes, 0)
        XCTAssertLessThanOrEqual(
            view.cachedTextVertexStorageBytes - view.cachedTextVertexBytes,
            4096
        )
    }

    func testIntegratedViewDynamicThumbnailVertexBudgetsScaleWithVisibleTerminalCount() {
        XCTAssertEqual(IntegratedView.effectiveThumbnailVertexSoftLimit(preferredTerminalCount: 0), 8)
        XCTAssertEqual(IntegratedView.effectiveThumbnailVertexSoftLimit(preferredTerminalCount: 3), 8)
        XCTAssertEqual(IntegratedView.effectiveThumbnailVertexSoftLimit(preferredTerminalCount: 12), 24)

        XCTAssertEqual(IntegratedView.effectiveThumbnailVertexSoftByteLimit(preferredTerminalCount: 0), 1 * 1024 * 1024)
        XCTAssertEqual(IntegratedView.effectiveThumbnailVertexSoftByteLimit(preferredTerminalCount: 4), 1 * 1024 * 1024)
        XCTAssertEqual(IntegratedView.effectiveThumbnailVertexSoftByteLimit(preferredTerminalCount: 16), 2 * 1024 * 1024)
        XCTAssertEqual(IntegratedView.effectiveThumbnailVertexSoftByteLimit(preferredTerminalCount: 128), 12 * 1024 * 1024)
    }

    func testIntegratedViewTerminalListDidChangeWithNoTerminalsReleasesOverviewCachesAndBuffers() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)

        view.debugPrimeTextVertexCache(texts: ["Alpha", "Beta", "Gamma"])
        view.debugEnsureLayoutCache()
        _ = renderer.reusableBuffer(
            for: view,
            slot: .overviewTextGlyph,
            vertices: Array(repeating: 1, count: 512)
        )
        _ = renderer.reusableBuffer(
            for: view,
            slot: .overviewThumbnailGlyph,
            vertices: Array(repeating: 1, count: 512)
        )

        XCTAssertGreaterThan(view.cachedTextVertexCount, 0)
        XCTAssertNotNil(renderer.bufferLength(for: view, slot: .overviewTextGlyph))
        XCTAssertNotNil(renderer.bufferLength(for: view, slot: .overviewThumbnailGlyph))

        view.terminalListDidChange()

        XCTAssertEqual(view.cachedTextVertexCount, 0)
        XCTAssertEqual(view.cachedThumbnailVertexCount, 0)
        XCTAssertEqual(view.cachedWorkspaceLayoutCount, 0)
        XCTAssertEqual(view.cachedFlattenedThumbnailCount, 0)
        XCTAssertEqual(view.cachedVisibleWorkspaceLayoutCount, 0)
        XCTAssertEqual(view.cachedVisibleThumbnailCount, 0)
        XCTAssertNil(renderer.bufferLength(for: view, slot: .overviewTextGlyph))
        XCTAssertNil(renderer.bufferLength(for: view, slot: .overviewThumbnailGlyph))
    }

    func testIntegratedViewIdlePurgeReleasesOverviewReusableBuffersAfterRenderedFrame() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        _ = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        renderFrame(for: view)

        XCTAssertTrue(renderer.hasOverviewBuffers(for: view))
        XCTAssertGreaterThan(view.cachedWorkspaceLayoutCount, 0)
        XCTAssertGreaterThan(view.cachedFlattenedThumbnailCount, 0)
        XCTAssertEqual(view.stagingVertexStorageBytes, 0)

        view.debugReleaseIdleBuffersNow()

        XCTAssertFalse(renderer.hasOverviewBuffers(for: view))
        XCTAssertEqual(view.drawableSize, .zero)
        XCTAssertEqual(view.stagingVertexStorageBytes, 0)
        XCTAssertEqual(view.cachedWorkspaceLayoutCount, 0)
        XCTAssertEqual(view.cachedFlattenedThumbnailCount, 0)
        XCTAssertEqual(view.cachedVisibleWorkspaceLayoutCount, 0)
        XCTAssertEqual(view.cachedVisibleThumbnailCount, 0)

        view.setNeedsDisplay(view.bounds)
        view.debugEnsureLayoutCache()

        XCTAssertGreaterThan(view.drawableSize.width, 0)
        XCTAssertGreaterThan(view.drawableSize.height, 0)
        XCTAssertGreaterThan(view.cachedWorkspaceLayoutCount, 0)
        XCTAssertGreaterThan(view.cachedFlattenedThumbnailCount, 0)
    }

    func testIntegratedViewRenderImmediatelyDropsTransientStagingVertices() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        _ = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        renderFrame(for: view)

        XCTAssertTrue(renderer.hasOverviewBuffers(for: view))
        XCTAssertEqual(view.stagingVertexStorageBytes, 0)
    }

    func testIntegratedViewIdlePurgeDropsOversizedRebuildableCaches() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        _ = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        renderFrame(for: view)
        view.debugInsertOversizedTextVertexCacheEntry(text: "huge-1", floatCount: 400_000)
        view.debugInsertOversizedThumbnailVertexCacheEntries(floatCountPerEntry: 300_000)
        XCTAssertGreaterThan(view.cachedTextVertexBytes, 256 * 1024)
        XCTAssertGreaterThan(view.cachedThumbnailVertexBytes, 64 * 1024)

        view.debugReleaseIdleBuffersNow()

        XCTAssertEqual(view.cachedTextVertexCount, 0)
        XCTAssertEqual(view.cachedThumbnailVertexCount, 0)
        XCTAssertFalse(renderer.hasOverviewBuffers(for: view))
        XCTAssertEqual(view.drawableSize, .zero)
    }

    func testIntegratedViewIdlePurgeClearsSmallRebuildableCachesToo() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        _ = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        renderFrame(for: view)
        view.debugPrimeTextVertexCache(texts: ["Alpha", "Beta"])
        view.debugPrimeThumbnailVertexCache(scaleFactor: 2.25)
        view.debugEnsureLayoutCache()
        view.debugInstallTooltipWindowForTesting()
        view.debugPrimeCloseTexturesForTesting()
        view.debugSeedCPUStatusCache(controllerID: manager.terminals[0].id)
        XCTAssertGreaterThan(view.cachedTextVertexCount, 0)
        XCTAssertGreaterThan(view.cachedThumbnailVertexCount, 0)
        XCTAssertGreaterThan(view.cachedCPUStatusCount, 0)
        XCTAssertGreaterThan(view.cachedWorkspaceLayoutCount, 0)
        XCTAssertGreaterThan(view.cachedFlattenedThumbnailCount, 0)
        XCTAssertTrue(view.hasTooltipWindow)
        XCTAssertTrue(view.hasCloseTextures)

        view.debugReleaseIdleBuffersNow()

        XCTAssertEqual(view.cachedTextVertexCount, 0)
        XCTAssertEqual(view.cachedThumbnailVertexCount, 0)
        XCTAssertEqual(view.cachedCPUStatusCount, 0)
        XCTAssertEqual(view.cachedWorkspaceLayoutCount, 0)
        XCTAssertEqual(view.cachedFlattenedThumbnailCount, 0)
        XCTAssertFalse(renderer.hasOverviewBuffers(for: view))
        XCTAssertEqual(view.drawableSize, .zero)
        XCTAssertFalse(view.hasTooltipWindow)
        XCTAssertFalse(view.hasCloseTextures)
    }

    func testIntegratedViewInactiveReleaseDropsDrawableAndOverviewBuffersImmediately() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let controller = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        XCTAssertTrue(view.setTerminalOutputActive(controller.id, isActive: true))
        renderFrame(for: view)

        XCTAssertTrue(renderer.hasOverviewBuffers(for: view))
        XCTAssertGreaterThan(view.drawableSize.width, 0)
        XCTAssertGreaterThan(view.cachedWorkspaceLayoutCount, 0)
        XCTAssertGreaterThan(view.cachedFlattenedThumbnailCount, 0)

        view.releaseInactiveRenderingResourcesNow()

        XCTAssertFalse(renderer.hasOverviewBuffers(for: view))
        XCTAssertEqual(view.drawableSize, .zero)
        XCTAssertEqual(view.stagingVertexStorageBytes, 0)
        XCTAssertEqual(view.cachedWorkspaceLayoutCount, 0)
        XCTAssertEqual(view.cachedFlattenedThumbnailCount, 0)

        view.setNeedsDisplay(view.bounds)
        view.debugEnsureLayoutCache()
        XCTAssertGreaterThan(view.drawableSize.width, 0)
        XCTAssertGreaterThan(view.drawableSize.height, 0)
        XCTAssertGreaterThan(view.cachedWorkspaceLayoutCount, 0)
        XCTAssertGreaterThan(view.cachedFlattenedThumbnailCount, 0)
    }

    func testIntegratedViewInactiveReleaseClearsRebuildableCaches() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        _ = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        renderFrame(for: view)
        view.debugPrimeTextVertexCache(texts: ["Alpha", "Beta", "Gamma"])
        view.debugPrimeThumbnailVertexCache(scaleFactor: 2.25)
        view.debugEnsureLayoutCache()
        view.debugInstallTooltipWindowForTesting()
        view.debugPrimeCloseTexturesForTesting()
        view.debugSeedCPUStatusCache(controllerID: manager.terminals[0].id, text: "CPU: 21.5%")
        XCTAssertGreaterThan(view.cachedTextVertexCount, 0)
        XCTAssertGreaterThan(view.cachedThumbnailVertexCount, 0)
        XCTAssertGreaterThan(view.cachedCPUStatusCount, 0)
        XCTAssertGreaterThan(view.cachedWorkspaceLayoutCount, 0)
        XCTAssertGreaterThan(view.cachedFlattenedThumbnailCount, 0)
        XCTAssertTrue(view.hasTooltipWindow)
        XCTAssertTrue(view.hasCloseTextures)

        view.releaseInactiveRenderingResourcesNow()

        XCTAssertEqual(view.cachedTextVertexCount, 0)
        XCTAssertEqual(view.cachedThumbnailVertexCount, 0)
        XCTAssertEqual(view.cachedCPUStatusCount, 0)
        XCTAssertEqual(view.cachedWorkspaceLayoutCount, 0)
        XCTAssertEqual(view.cachedFlattenedThumbnailCount, 0)
        XCTAssertFalse(renderer.hasOverviewBuffers(for: view))
        XCTAssertEqual(view.drawableSize, .zero)
        XCTAssertFalse(view.hasTooltipWindow)
        XCTAssertFalse(view.hasCloseTextures)
    }

    func testIntegratedViewMemoryPressureCompactionReleasesOverviewBuffersWithoutDiscardingVisibleDrawable() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let controller = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        XCTAssertTrue(view.setTerminalOutputActive(controller.id, isActive: true))
        renderFrame(for: view)
        let originalDrawableSize = view.drawableSize
        view.debugInstallTooltipWindowForTesting()
        view.debugPrimeCloseTexturesForTesting()
        view.debugSeedCPUStatusCache(controllerID: controller.id, text: "CPU: 9.4%")
        XCTAssertTrue(renderer.hasOverviewBuffers(for: view))
        XCTAssertGreaterThan(originalDrawableSize.width, 0)
        XCTAssertGreaterThan(view.cachedCPUStatusCount, 0)
        XCTAssertGreaterThan(view.stagingVertexStorageBytes, 0)
        XCTAssertGreaterThan(view.cachedWorkspaceLayoutCount, 0)
        XCTAssertGreaterThan(view.cachedFlattenedThumbnailCount, 0)
        XCTAssertTrue(view.hasTooltipWindow)
        XCTAssertTrue(view.hasCloseTextures)

        view.compactForMemoryPressureNow()

        XCTAssertFalse(renderer.hasOverviewBuffers(for: view))
        XCTAssertEqual(view.drawableSize, originalDrawableSize)
        XCTAssertEqual(view.cachedCPUStatusCount, 0)
        XCTAssertEqual(view.stagingVertexStorageBytes, 0)
        XCTAssertEqual(view.cachedWorkspaceLayoutCount, 0)
        XCTAssertEqual(view.cachedFlattenedThumbnailCount, 0)
        XCTAssertFalse(view.hasTooltipWindow)
        XCTAssertFalse(view.hasCloseTextures)
    }

    func testIntegratedViewCPUStatusCacheDoesNotRetainNilEntries() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let controller = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        XCTAssertEqual(view.cachedCPUStatusCount, 0)

        view.debugSeedCPUStatusCache(controllerID: controller.id, text: nil)

        XCTAssertEqual(view.cachedCPUStatusCount, 0)
    }

    func testIntegratedViewCPUStatusCacheRemovesExistingEntryWhenTextBecomesNil() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let controller = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        view.debugSeedCPUStatusCache(controllerID: controller.id, text: "CPU: 13.7%")
        XCTAssertEqual(view.cachedCPUStatusCount, 1)

        view.debugSeedCPUStatusCache(controllerID: controller.id, text: nil)

        XCTAssertEqual(view.cachedCPUStatusCount, 0)
    }

    func testSplitRenderViewIdlePurgeReleasesDrawableStorageAndRestoresOnRequestRender() throws {
        let renderer = try makeRendererOrSkip()
        let splitRenderView = SplitRenderView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), renderer: renderer)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(splitRenderView)
        window.makeKeyAndOrderFront(nil)
        drainMainQueue(testCase: self)

        splitRenderView.syncScaleFactorIfNeeded()
        XCTAssertGreaterThan(splitRenderView.drawableSize.width, 0)

        splitRenderView.debugReleaseIdleBuffersNow()

        XCTAssertEqual(splitRenderView.drawableSize, .zero)

        splitRenderView.requestRender()

        XCTAssertGreaterThan(splitRenderView.drawableSize.width, 0)
        XCTAssertGreaterThan(splitRenderView.drawableSize.height, 0)
    }

    func testSplitTerminalContainerInactiveReleaseDropsChildAndOverlayDrawables() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let controllers = (0..<2).map { index in
            TerminalController(
                rows: 4,
                cols: 12,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: "/tmp/inactive-split-\(index)"
            )
        }
        let container = SplitTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), renderer: renderer, controllers: controllers)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320))
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(container)
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()
        drainMainQueue(testCase: self)

        guard let splitRenderView = allSubviews(in: container).compactMap({ $0 as? SplitRenderView }).first else {
            XCTFail("SplitRenderView missing")
            return
        }
        let terminalViews = allSubviews(in: container).compactMap { $0 as? TerminalView }

        splitRenderView.requestRender()
        for terminalView in terminalViews {
            terminalView.setNeedsDisplay(terminalView.bounds)
        }

        XCTAssertTrue(terminalViews.allSatisfy { $0.drawableSize == .zero || $0.drawableSize.width > 0 })
        XCTAssertGreaterThan(splitRenderView.drawableSize.width, 0)

        container.releaseInactiveRenderingResourcesNow()

        XCTAssertTrue(terminalViews.allSatisfy { $0.drawableSize == .zero })
        XCTAssertEqual(splitRenderView.drawableSize, .zero)

        container.requestRender()
        XCTAssertGreaterThan(splitRenderView.drawableSize.width, 0)
        XCTAssertGreaterThan(splitRenderView.drawableSize.height, 0)
    }

    func testSplitTerminalContainerMemoryPressureCompactionReleasesOverlayBuffersWhileKeepingVisibleDrawable() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let controllers = (0..<2).map { index in
            TerminalController(
                rows: 4,
                cols: 12,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: "/tmp/memory-pressure-split-\(index)"
            )
        }
        let container = SplitTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), renderer: renderer, controllers: controllers)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320))
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(container)
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()
        drainMainQueue(testCase: self)

        guard let splitRenderView = allSubviews(in: container).compactMap({ $0 as? SplitRenderView }).first else {
            XCTFail("SplitRenderView missing")
            return
        }

        renderFrame(for: splitRenderView)
        let originalDrawableSize = splitRenderView.drawableSize
        XCTAssertGreaterThan(originalDrawableSize.width, 0)

        container.compactForMemoryPressureNow()

        XCTAssertEqual(splitRenderView.drawableSize, originalDrawableSize)
    }

    func testReusableOverviewBufferShrinksAfterLargePeakUsageDrops() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)

        _ = renderer.reusableBuffer(
            for: view,
            slot: .overviewTextGlyph,
            vertices: Array(repeating: 1, count: 100_000)
        )
        let largeLength = try XCTUnwrap(renderer.bufferLength(for: view, slot: .overviewTextGlyph))

        _ = renderer.reusableBuffer(
            for: view,
            slot: .overviewTextGlyph,
            vertices: Array(repeating: 1, count: 128)
        )
        let smallLength = try XCTUnwrap(renderer.bufferLength(for: view, slot: .overviewTextGlyph))

        XCTAssertLessThan(smallLength, largeLength)
        XCTAssertGreaterThanOrEqual(smallLength, 128 * MemoryLayout<Float>.size)
    }

    func testReusableOverviewBufferUsesBoundedHeadroomInsteadOfLargePeakSlack() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)

        let requiredFloats = 1_024
        let requiredBytes = requiredFloats * MemoryLayout<Float>.size
        _ = renderer.reusableBuffer(
            for: view,
            slot: .overviewTextGlyph,
            vertices: Array(repeating: 1, count: requiredFloats)
        )
        let length = try XCTUnwrap(renderer.bufferLength(for: view, slot: .overviewTextGlyph))
        let expectedAlignedLength = 8 * 1024

        XCTAssertGreaterThanOrEqual(length, requiredBytes)
        XCTAssertEqual(length, expectedAlignedLength)
        XCTAssertLessThan(length, requiredBytes * 5)
    }

    func testReusableOverviewBufferCapsHeadroomForLargePayloads() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)

        let requiredFloats = 300_000
        let requiredBytes = requiredFloats * MemoryLayout<Float>.size
        _ = renderer.reusableBuffer(
            for: view,
            slot: .overviewThumbnailGlyph,
            vertices: Array(repeating: 1, count: requiredFloats)
        )
        let length = try XCTUnwrap(renderer.bufferLength(for: view, slot: .overviewThumbnailGlyph))

        XCTAssertGreaterThanOrEqual(length, requiredBytes)
        XCTAssertLessThanOrEqual(length, requiredBytes + (64 * 1024) + (4 * 1024))
    }

    func testReusableOverviewBufferReleasesStorageWhenVertexPayloadBecomesEmpty() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)

        _ = renderer.reusableBuffer(
            for: view,
            slot: .overviewThumbnailGlyph,
            vertices: Array(repeating: 1, count: 256)
        )
        XCTAssertNotNil(renderer.bufferLength(for: view, slot: .overviewThumbnailGlyph))

        _ = renderer.reusableBuffer(for: view, slot: .overviewThumbnailGlyph, vertices: [])

        XCTAssertNil(renderer.bufferLength(for: view, slot: .overviewThumbnailGlyph))
    }

    func testIntegratedViewTerminalListDidChangeRefreshesCachedLayoutsImmediatelyAfterAdd() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        _ = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        renderFrame(for: view)
        XCTAssertEqual(reflectedWorkspaceLayouts(from: view).flatMap(\.terminals).count, 1)

        _ = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        view.terminalListDidChange()

        XCTAssertEqual(reflectedWorkspaceLayouts(from: view).flatMap(\.terminals).count, 2)
    }

    func testIntegratedViewTerminalListDidChangeRefreshesCachedLayoutsImmediatelyAfterRemove() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let first = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )
        _ = try manager.addTerminal(
            initialDirectory: NSTemporaryDirectory(),
            workspaceName: "WS",
            fontName: renderer.glyphAtlas.fontName,
            fontSize: Double(renderer.glyphAtlas.fontSize)
        )

        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220))
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let overlay = ScrollbarOverlayView(frame: view.frame)
        overlay.documentView = ScrollDocumentView(frame: view.bounds)
        overlay.contentView.postsBoundsChangedNotifications = true
        view.companionScrollView = overlay

        renderFrame(for: view)
        XCTAssertEqual(reflectedWorkspaceLayouts(from: view).flatMap(\.terminals).count, 2)

        manager.removeTerminal(first, preserveScrollback: true)
        view.terminalListDidChange()

        XCTAssertEqual(reflectedWorkspaceLayouts(from: view).flatMap(\.terminals).count, 1)
    }

    func testIntegratedViewRespondsToSimulatedDisplayScaleChange() throws {
        guard let renderer = MetalRenderer(scaleFactor: 1.0) else {
            throw XCTSkip("Metal unavailable")
        }
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)

        view.viewDidMoveToWindow()
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 1.0)
        XCTAssertEqual(Double(view.drawableSize.width), 640, accuracy: 1.0)
        XCTAssertEqual(Double(view.drawableSize.height), 360, accuracy: 1.0)

        window.testBackingScaleFactor = 2.0
        view.viewDidChangeBackingProperties()

        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 2.0)
        XCTAssertEqual(Double(view.drawableSize.width), 1280, accuracy: 1.0)
        XCTAssertEqual(Double(view.drawableSize.height), 720, accuracy: 1.0)
    }

    func testIntegratedViewResizeImmediatelyUpdatesDrawableSizeBeforeNextDraw() throws {
        guard let renderer = MetalRenderer(scaleFactor: 2.0) else {
            throw XCTSkip("Metal unavailable")
        }
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420))
        window.testBackingScaleFactor = 2.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)

        view.viewDidMoveToWindow()
        XCTAssertEqual(Double(view.drawableSize.width), 1280, accuracy: 1.0)
        XCTAssertEqual(Double(view.drawableSize.height), 720, accuracy: 1.0)

        view.setFrameSize(NSSize(width: 500, height: 280))

        XCTAssertEqual(Double(view.drawableSize.width), 1000, accuracy: 1.0)
        XCTAssertEqual(Double(view.drawableSize.height), 560, accuracy: 1.0)
    }

    func testSplitTerminalContainerRespondsToSimulatedDisplayScaleChangeAcrossOverlayAndTerminalViews() throws {
        guard let renderer = MetalRenderer(scaleFactor: 1.0) else {
            throw XCTSkip("Metal unavailable")
        }
        let controllers = (0..<2).map { index in
            TerminalController(
                rows: 4,
                cols: 12,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: "/tmp/dpi\(index)"
            )
        }
        let container = SplitTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), renderer: renderer, controllers: controllers)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(container)
        container.layoutSubtreeIfNeeded()

        let terminalViews = allSubviews(in: container).compactMap { $0 as? TerminalView }
        let splitRenderView = try XCTUnwrap(allSubviews(in: container).compactMap { $0 as? SplitRenderView }.first)
        terminalViews.forEach { $0.viewDidMoveToWindow() }
        splitRenderView.viewDidMoveToWindow()
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 1.0)
        XCTAssertEqual(splitRenderView.layer?.contentsScale, 1.0)

        window.testBackingScaleFactor = 2.0
        terminalViews.forEach { $0.viewDidChangeBackingProperties() }
        splitRenderView.viewDidChangeBackingProperties()

        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 2.0)
        XCTAssertEqual(splitRenderView.layer?.contentsScale, 2.0)
        XCTAssertTrue(terminalViews.allSatisfy { $0.renderer?.glyphAtlas.scaleFactor == 2.0 })
    }

    func testSplitTerminalContainerKeepsIMEOverlayAndScaleInSyncAcrossDisplayChanges() throws {
        let renderer = try makeRendererOrSkip()
        let controllers = (0..<2).map { index in
            TerminalController(
                rows: 4,
                cols: 12,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: "/tmp/ime\(index)"
            )
        }
        let container = SplitTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), renderer: renderer, controllers: controllers)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(container)
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()

        let terminalViews = allSubviews(in: container).compactMap { $0 as? TerminalView }
        XCTAssertEqual(terminalViews.count, 2)
        terminalViews[0].setMarkedText("未確定", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        container.updateMarkedTextForFontChange()

        for scale in [1.0 as CGFloat, 2.0, 1.5] {
            window.testBackingScaleFactor = scale
            terminalViews.forEach { $0.viewDidChangeBackingProperties() }
            (allSubviews(in: container).first { $0 is SplitRenderView } as? SplitRenderView)?.viewDidChangeBackingProperties()
            container.updateMarkedTextForFontChange()

            let markedLayer = try XCTUnwrap(terminalViews[0].layer?.sublayers?.compactMap { $0 as? CATextLayer }.first)
            XCTAssertEqual(markedLayer.contentsScale, scale)
            XCTAssertFalse(markedLayer.isHidden)
            XCTAssertEqual(renderer.glyphAtlas.scaleFactor, scale)
        }
    }

    func testSplitTerminalContainerUnmarkTextAfterDisplayScaleChangeKeepsOverlayHiddenAtUpdatedScale() throws {
        let renderer = try makeRendererOrSkip()
        let controllers = (0..<2).map { index in
            TerminalController(
                rows: 4,
                cols: 12,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: "/tmp/unmark\(index)"
            )
        }
        let container = SplitTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), renderer: renderer, controllers: controllers)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(container)
        container.layoutSubtreeIfNeeded()

        let terminalView = try XCTUnwrap(allSubviews(in: container).compactMap { $0 as? TerminalView }.first)
        terminalView.setMarkedText("未確定", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        window.testBackingScaleFactor = 2.0
        terminalView.viewDidChangeBackingProperties()
        terminalView.unmarkText()

        XCTAssertTrue(terminalView.layer?.sublayers?.compactMap { $0 as? CATextLayer }.isEmpty ?? true)
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 2.0)
    }

    func testSplitTerminalContainerUpdateControllersAfterDisplayScaleChangeKeepsOverlayScale() throws {
        let renderer = try makeRendererOrSkip()
        let initialControllers = (0..<2).map { index in
            TerminalController(
                rows: 4,
                cols: 12,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: "/tmp/replace-a\(index)"
            )
        }
        let replacementControllers = (0..<3).map { index in
            TerminalController(
                rows: 4,
                cols: 12,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: "/tmp/replace-b\(index)"
            )
        }
        let container = SplitTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), renderer: renderer, controllers: initialControllers)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320))
        window.testBackingScaleFactor = 2.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(container)
        container.layoutSubtreeIfNeeded()

        let initialTerminalViews = allSubviews(in: container).compactMap { $0 as? TerminalView }
        initialTerminalViews.forEach { $0.viewDidMoveToWindow() }
        try XCTUnwrap(allSubviews(in: container).compactMap { $0 as? SplitRenderView }.first).viewDidMoveToWindow()
        container.updateControllers(replacementControllers)
        container.layoutSubtreeIfNeeded()

        let replacementTerminalViews = allSubviews(in: container).compactMap { $0 as? TerminalView }
        let splitRenderView = try XCTUnwrap(allSubviews(in: container).compactMap { $0 as? SplitRenderView }.first)

        XCTAssertEqual(replacementTerminalViews.count, 3)
        XCTAssertTrue(replacementTerminalViews.allSatisfy { $0.renderer?.glyphAtlas.scaleFactor == 2.0 })
        XCTAssertEqual(splitRenderView.layer?.contentsScale, 2.0)
    }

    func testSplitTerminalContainerFontChangeAfterDisplayScaleChangeKeepsOverlayScale() throws {
        let renderer = try makeRendererOrSkip()
        let controllers = (0..<2).map { index in
            TerminalController(
                rows: 4,
                cols: 12,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: "/tmp/fontscale\(index)"
            )
        }
        let container = SplitTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), renderer: renderer, controllers: controllers)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(container)
        container.layoutSubtreeIfNeeded()

        let terminalViews = allSubviews(in: container).compactMap { $0 as? TerminalView }
        terminalViews.forEach { $0.viewDidMoveToWindow() }
        let splitRenderView = try XCTUnwrap(allSubviews(in: container).compactMap { $0 as? SplitRenderView }.first)
        splitRenderView.viewDidMoveToWindow()

        window.testBackingScaleFactor = 2.0
        terminalViews.forEach { $0.viewDidChangeBackingProperties() }
        splitRenderView.viewDidChangeBackingProperties()
        container.fontSizeDidChange()
        container.updateMarkedTextForFontChange()
        container.layoutSubtreeIfNeeded()

        XCTAssertTrue(terminalViews.allSatisfy { $0.renderer?.glyphAtlas.scaleFactor == 2.0 })
        XCTAssertEqual(splitRenderView.layer?.contentsScale, 2.0)
    }

    func testSplitTerminalContainerSyncScaleFactorIfNeededUpdatesSplitRenderViewAndTerminalViews() throws {
        let renderer = try makeRendererOrSkip()
        let controllers = (0..<2).map { index in
            TerminalController(
                rows: 4,
                cols: 12,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: "/tmp/syncscale\(index)"
            )
        }
        let container = SplitTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), renderer: renderer, controllers: controllers)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(container)
        container.layoutSubtreeIfNeeded()

        let terminalViews = allSubviews(in: container).compactMap { $0 as? TerminalView }
        terminalViews.forEach { $0.viewDidMoveToWindow() }
        let splitRenderView = try XCTUnwrap(allSubviews(in: container).compactMap { $0 as? SplitRenderView }.first)
        splitRenderView.viewDidMoveToWindow()

        XCTAssertTrue(terminalViews.allSatisfy { $0.renderer?.glyphAtlas.scaleFactor == 1.0 })
        XCTAssertEqual(splitRenderView.layer?.contentsScale, 1.0)
        XCTAssertEqual(splitRenderView.drawableSize.width, 420.0, accuracy: 0.5)
        XCTAssertEqual(splitRenderView.drawableSize.height, 260.0, accuracy: 0.5)

        window.testBackingScaleFactor = 2.0
        container.syncScaleFactorIfNeeded()

        XCTAssertTrue(terminalViews.allSatisfy { $0.renderer?.glyphAtlas.scaleFactor == 2.0 })
        XCTAssertEqual(splitRenderView.layer?.contentsScale, 2.0)
        XCTAssertEqual(splitRenderView.drawableSize.width, 840.0, accuracy: 0.5)
        XCTAssertEqual(splitRenderView.drawableSize.height, 520.0, accuracy: 0.5)
    }

    func testIntegratedViewShiftSelectionCommitsMultiSelectOnShiftRelease() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        _ = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        _ = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), renderer: renderer, manager: manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        renderFrame(for: view)

        let layouts = try XCTUnwrap(reflectedWorkspaceLayouts(from: view).first)
        XCTAssertGreaterThanOrEqual(layouts.terminals.count, 2)
        let firstPoint = try XCTUnwrap(layouts.terminals.first?.thumbnail.center)
        let secondPoint = try XCTUnwrap(layouts.terminals.dropFirst().first?.thumbnail.center)
        view.mouseDown(with: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: firstPoint, in: view, window: window, modifiers: [.shift])))
        view.mouseDown(with: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: secondPoint, in: view, window: window, modifiers: [.shift])))

        var multiSelectedIDs: [UUID] = []
        view.onMultiSelect = { multiSelectedIDs = $0.map(\.id) }
        view.flagsChanged(with: try XCTUnwrap(makeFlagsEvent(window: window, modifiers: [])))

        XCTAssertEqual(Set(multiSelectedIDs), Set(manager.terminals.map(\.id)))
        XCTAssertTrue(view.selectedTerminals.isEmpty)
    }

    func testIntegratedViewShiftSelectionStillCommitsAfterDisplayScaleChange() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        _ = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        _ = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), renderer: renderer, manager: manager)
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        renderFrame(for: view)

        let layouts = try XCTUnwrap(reflectedWorkspaceLayouts(from: view).first)
        let firstPoint = try XCTUnwrap(layouts.terminals.first?.thumbnail.center)
        let secondPoint = try XCTUnwrap(layouts.terminals.dropFirst().first?.thumbnail.center)
        view.mouseDown(with: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: firstPoint, in: view, window: window, modifiers: [.shift])))
        window.testBackingScaleFactor = 2.0
        view.viewDidChangeBackingProperties()
        renderFrame(for: view)
        view.mouseDown(with: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: secondPoint, in: view, window: window, modifiers: [.shift])))

        var multiSelectedIDs: [UUID] = []
        view.onMultiSelect = { multiSelectedIDs = $0.map(\.id) }
        view.flagsChanged(with: try XCTUnwrap(makeFlagsEvent(window: window, modifiers: [])))

        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 2.0)
        XCTAssertEqual(Set(multiSelectedIDs), Set(manager.terminals.map(\.id)))
    }

    func testIntegratedViewThumbnailClickClearsExistingSelectionAndInvokesSelectCallback() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let first = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        let second = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), renderer: renderer, manager: manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        renderFrame(for: view)

        let layouts = try XCTUnwrap(reflectedWorkspaceLayouts(from: view).first)
        let firstPoint = try XCTUnwrap(layouts.terminals.first(where: { $0.controllerID == first.id })?.thumbnail.center)
        let secondPoint = try XCTUnwrap(layouts.terminals.first(where: { $0.controllerID == second.id })?.thumbnail.center)
        view.mouseDown(with: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: firstPoint, in: view, window: window, modifiers: [.shift])))
        XCTAssertEqual(view.selectedTerminals, Set([first.id]))

        var selectedID: UUID?
        view.onSelectTerminal = { selectedID = $0.id }
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: secondPoint, in: view, window: window))
        let up = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, point: secondPoint, in: view, window: window))
        view.mouseDown(with: down)
        view.mouseUp(with: up)

        XCTAssertEqual(selectedID, second.id)
        XCTAssertTrue(view.selectedTerminals.isEmpty)
    }

    func testIntegratedViewThumbnailClickWorksBeforeFirstRenderedFrame() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let terminal = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), renderer: renderer, manager: manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)

        view.debugEnsureLayoutCache()
        let layout = try XCTUnwrap(reflectedWorkspaceLayouts(from: view).first?.terminals.first(where: { $0.controllerID == terminal.id }))
        let clickPoint = layout.thumbnail.center
        view.debugReleaseLayoutStorageForTesting()
        XCTAssertEqual(view.cachedWorkspaceLayoutCount, 0)

        var selectedID: UUID?
        view.onSelectTerminal = { selectedID = $0.id }
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: clickPoint, in: view, window: window))
        let up = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, point: clickPoint, in: view, window: window))
        view.mouseDown(with: down)
        view.mouseUp(with: up)

        XCTAssertEqual(selectedID, terminal.id)
        XCTAssertGreaterThan(view.cachedWorkspaceLayoutCount, 0)
    }

    func testIntegratedViewEmptyStateShowsAndHandlesAddWorkspaceButton() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), renderer: renderer, manager: manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        renderFrame(for: view)

        let addWorkspaceButtonFrame = try XCTUnwrap(reflectedAddWorkspaceButtonFrame(from: view))
        XCTAssertFalse(addWorkspaceButtonFrame.isEmpty)

        var didRequestAddWorkspace = false
        view.onAddWorkspace = { didRequestAddWorkspace = true }
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: addWorkspaceButtonFrame.center, in: view, window: window))
        view.mouseDown(with: down)

        XCTAssertTrue(didRequestAddWorkspace)
    }

    func testIntegratedViewTitleBarSingleClickDoesNotInvokeSelectCallback() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let terminal = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), renderer: renderer, manager: manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        renderFrame(for: view)

        let layout = try XCTUnwrap(reflectedWorkspaceLayouts(from: view).first?.terminals.first(where: { $0.controllerID == terminal.id }))
        var didSelect = false
        view.onSelectTerminal = { _ in didSelect = true }
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: layout.title.center, in: view, window: window))
        let up = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, point: layout.title.center, in: view, window: window))
        view.mouseDown(with: down)
        view.mouseUp(with: up)

        XCTAssertFalse(didSelect)
    }

    func testIntegratedViewCloseButtonInvokesRemoveTerminalCallbackInsteadOfDirectRemoval() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let terminal = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), renderer: renderer, manager: manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        renderFrame(for: view)

        let layout = try XCTUnwrap(reflectedWorkspaceLayouts(from: view).first?.terminals.first(where: { $0.controllerID == terminal.id }))
        var removedID: UUID?
        view.onRemoveTerminal = { removedID = $0.id }

        let closePoint = NSPoint(x: layout.title.minX + 8, y: layout.title.midY)
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: closePoint, in: view, window: window))
        view.mouseDown(with: down)

        XCTAssertEqual(removedID, terminal.id)
        XCTAssertEqual(manager.terminals.count, 1)
    }

    func testTerminalRemovalConfirmationUsesCustomTitleWhenPresent() {
        let confirmation = AppDelegate.terminalRemovalConfirmation(
            customTitle: "Build Logs",
            fallbackTitle: "wk"
        )

        XCTAssertEqual(confirmation.title, "Remove Terminal?")
        XCTAssertEqual(confirmation.confirmButton, "Remove Terminal")
        XCTAssertEqual(confirmation.message, "This will stop and remove \"Build Logs\" from the overview.")
    }

    func testWorkspaceRemovalConfirmationIncludesWorkspaceNameAndTerminalCount() {
        let confirmation = AppDelegate.workspaceRemovalConfirmation(
            workspaceName: "Alpha",
            terminalCount: 2
        )

        XCTAssertEqual(confirmation.title, "Remove Workspace?")
        XCTAssertEqual(confirmation.confirmButton, "Remove Workspace")
        XCTAssertEqual(confirmation.message, "This will stop and remove the workspace \"Alpha\" and its 2 terminals.")
    }

    func testIntegratedViewSelectAllButtonSelectsWorkspaceTerminals() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let a1 = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), workspaceName: "Alpha", fontName: "Menlo", fontSize: 13)
        let a2 = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), workspaceName: "Alpha", fontName: "Menlo", fontSize: 13)
        _ = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), workspaceName: "Beta", fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 960, height: 480), renderer: renderer, manager: manager)
        view.explicitWorkspaceNames = ["Alpha", "Beta"]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 540),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        renderFrame(for: view)

        view.flagsChanged(with: try XCTUnwrap(makeFlagsEvent(window: window, modifiers: [.shift])))
        let alphaLayout = try XCTUnwrap(reflectedWorkspaceLayouts(from: view).first(where: { $0.name == "Alpha" }))
        view.mouseDown(with: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: alphaLayout.selectAllFrame.center, in: view, window: window, modifiers: [.shift])))

        XCTAssertEqual(view.selectedTerminals, Set([a1.id, a2.id]))
    }

    func testIntegratedViewDeselectButtonClearsWorkspaceSelection() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let a1 = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), workspaceName: "Alpha", fontName: "Menlo", fontSize: 13)
        let a2 = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), workspaceName: "Alpha", fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 960, height: 480), renderer: renderer, manager: manager)
        view.explicitWorkspaceNames = ["Alpha"]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 540),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        renderFrame(for: view)

        view.flagsChanged(with: try XCTUnwrap(makeFlagsEvent(window: window, modifiers: [.shift])))
        let alphaLayout = try XCTUnwrap(reflectedWorkspaceLayouts(from: view).first(where: { $0.name == "Alpha" }))
        view.mouseDown(with: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: alphaLayout.selectAllFrame.center, in: view, window: window, modifiers: [.shift])))
        XCTAssertEqual(view.selectedTerminals, Set([a1.id, a2.id]))
        view.mouseDown(with: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: alphaLayout.deselectFrame.center, in: view, window: window, modifiers: [.shift])))

        XCTAssertTrue(view.selectedTerminals.isEmpty)
    }

    func testIntegratedViewWorkspaceOrderPreservesExplicitNamesAndAppendsUncategorized() throws {
        let renderer = try makeRendererOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        _ = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), workspaceName: "Beta", fontName: "Menlo", fontSize: 13)
        _ = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), workspaceName: "", fontName: "Menlo", fontSize: 13)
        _ = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), workspaceName: "Alpha", fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 960, height: 480), renderer: renderer, manager: manager)
        view.explicitWorkspaceNames = ["Alpha", "Beta"]

        let names = reflectedWorkspaceLayouts(from: view).map(\.name)

        XCTAssertEqual(names, ["Alpha", "Beta", "Uncategorized"])
    }

    func testIntegratedViewBackShortcutFromSplitContainerInvokesOverviewCallback() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = SplitTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), renderer: renderer, controllers: [controller])
        var didBack = false
        view.onBackToIntegrated = { didBack = true }

        guard let scrollView = allSubviews(in: view).first(where: { $0 is TerminalScrollView }) as? TerminalScrollView else {
            XCTFail("TerminalScrollView missing")
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "`",
            charactersIgnoringModifiers: "`",
            isARepeat: false,
            keyCode: 50
        )
        XCTAssertTrue(scrollView.performKeyEquivalent(with: try XCTUnwrap(event)))
        XCTAssertTrue(didBack)
    }

    func testIntegratedViewBackShortcutFromSplitContainerStillWorksAfterDisplayScaleChange() throws {
        let renderer = try makeRendererOrSkip()
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        let view = SplitTerminalContainerView(frame: NSRect(x: 0, y: 0, width: 420, height: 260), renderer: renderer, controllers: [controller])
        var didBack = false
        view.onBackToIntegrated = { didBack = true }

        guard let scrollView = allSubviews(in: view).first(where: { $0 is TerminalScrollView }) as? TerminalScrollView else {
            XCTFail("TerminalScrollView missing")
            return
        }

        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        window.testBackingScaleFactor = 2.0
        allSubviews(in: view).compactMap { $0 as? TerminalView }.forEach { $0.viewDidChangeBackingProperties() }
        (allSubviews(in: view).first { $0 is SplitRenderView } as? SplitRenderView)?.viewDidChangeBackingProperties()

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "`",
            charactersIgnoringModifiers: "`",
            isARepeat: false,
            keyCode: 50
        )
        XCTAssertTrue(scrollView.performKeyEquivalent(with: try XCTUnwrap(event)))
        XCTAssertTrue(didBack)
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 2.0)
    }

    func testIntegratedViewDragReorderTerminalAndWorkspaceCallbacks() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let first = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), workspaceName: "Alpha", fontName: "Menlo", fontSize: 13)
        _ = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), workspaceName: "Beta", fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 960, height: 480), renderer: renderer, manager: manager)
        view.explicitWorkspaceNames = ["Alpha", "Beta"]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 540),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        renderFrame(for: view)
        let layouts = reflectedWorkspaceLayouts(from: view)
        let alphaLayout = try XCTUnwrap(layouts.first(where: { $0.name == "Alpha" }))
        let betaLayout = try XCTUnwrap(layouts.first(where: { $0.name == "Beta" }))

        let terminalPB = NSPasteboard(name: .drag)
        terminalPB.clearContents()
        terminalPB.setString(first.id.uuidString, forType: .string)
        terminalPB.setString(first.id.uuidString, forType: NSPasteboard.PasteboardType("com.pterm.terminal-id"))

        var movedTerminal: (UUID, String)?
        var reorderedTerminal: (UUID, String, Int)?
        view.onMoveTerminalToWorkspace = { controller, workspace in
            movedTerminal = (controller.id, workspace)
        }
        view.onReorderTerminal = { controller, workspace, index in
            reorderedTerminal = (controller.id, workspace, index)
        }

        let terminalHeaderDrop = TestDraggingInfo(pasteboard: terminalPB, location: view.convert(betaLayout.headerFrame.center, to: nil))
        XCTAssertTrue(view.performDragOperation(terminalHeaderDrop))
        XCTAssertEqual(movedTerminal?.0, first.id)
        XCTAssertEqual(movedTerminal?.1, "Beta")

        let betaTerminalFrame = try XCTUnwrap(betaLayout.terminals.first?.title.union(betaLayout.terminals.first?.thumbnail ?? .zero))
        let terminalReorderPoint = NSPoint(x: betaTerminalFrame.maxX + 8, y: betaTerminalFrame.midY)
        let terminalGridDrop = TestDraggingInfo(pasteboard: terminalPB, location: view.convert(terminalReorderPoint, to: nil))
        XCTAssertTrue(view.performDragOperation(terminalGridDrop))
        XCTAssertEqual(reorderedTerminal?.0, first.id)
        XCTAssertEqual(reorderedTerminal?.1, "Beta")
        XCTAssertEqual(reorderedTerminal?.2, 1)

        let workspacePB = NSPasteboard(name: .find)
        workspacePB.clearContents()
        workspacePB.setString("Alpha", forType: NSPasteboard.PasteboardType("com.pterm.workspace-name"))

        var reorderedWorkspace: (String, Int)?
        view.onReorderWorkspace = { workspace, index in
            reorderedWorkspace = (workspace, index)
        }

        let workspaceDropPoint = NSPoint(x: alphaLayout.frame.midX, y: max(layouts.map(\.frame.maxY).max() ?? alphaLayout.frame.maxY, betaLayout.frame.maxY) + 24)
        let workspaceDrop = TestDraggingInfo(pasteboard: workspacePB, location: view.convert(workspaceDropPoint, to: nil))
        XCTAssertTrue(view.performDragOperation(workspaceDrop))
        XCTAssertEqual(reorderedWorkspace?.0, "Alpha")
        XCTAssertEqual(reorderedWorkspace?.1, layouts.count)
    }

    func testIntegratedViewDragReorderCallbacksStillWorkAfterDisplayScaleChange() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        let first = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), workspaceName: "Alpha", fontName: "Menlo", fontSize: 13)
        _ = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), workspaceName: "Beta", fontName: "Menlo", fontSize: 13)
        let view = IntegratedView(frame: NSRect(x: 0, y: 0, width: 960, height: 480), renderer: renderer, manager: manager)
        view.explicitWorkspaceNames = ["Alpha", "Beta"]
        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 540))
        window.testBackingScaleFactor = 1.0
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        renderFrame(for: view)

        window.testBackingScaleFactor = 2.0
        view.viewDidChangeBackingProperties()
        renderFrame(for: view)

        let layouts = reflectedWorkspaceLayouts(from: view)
        let betaLayout = try XCTUnwrap(layouts.first(where: { $0.name == "Beta" }))
        let terminalPB = NSPasteboard(name: .drag)
        terminalPB.clearContents()
        terminalPB.setString(first.id.uuidString, forType: .string)
        terminalPB.setString(first.id.uuidString, forType: NSPasteboard.PasteboardType("com.pterm.terminal-id"))

        var movedTerminal: (UUID, String)?
        view.onMoveTerminalToWorkspace = { controller, workspace in
            movedTerminal = (controller.id, workspace)
        }

        let terminalHeaderDrop = TestDraggingInfo(pasteboard: terminalPB, location: view.convert(betaLayout.headerFrame.center, to: nil))
        XCTAssertTrue(view.performDragOperation(terminalHeaderDrop))
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 2.0)
        XCTAssertEqual(movedTerminal?.0, first.id)
        XCTAssertEqual(movedTerminal?.1, "Beta")
    }

    func testIntegratedToSplitToOverviewRoundTripKeepsScaleSync() throws {
        let renderer = try makeRendererWithPipelinesOrSkip()
        let manager = TerminalManager(rows: 24, cols: 80, config: .default)
        defer { manager.stopAll(waitForExit: true) }
        _ = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), workspaceName: "Alpha", fontName: "Menlo", fontSize: 13)
        _ = try manager.addTerminal(initialDirectory: NSTemporaryDirectory(), workspaceName: "Alpha", fontName: "Menlo", fontSize: 13)

        let window = TestScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540))
        window.testBackingScaleFactor = 1.0
        let contentRect = window.contentRect(forFrameRect: window.frame)
        let contentView = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        window.contentView = contentView
        let integratedView = IntegratedView(frame: contentView.bounds, renderer: renderer, manager: manager)
        contentView.addSubview(integratedView)
        window.makeKeyAndOrderFront(nil)
        renderFrame(for: integratedView)

        var createdSplit: SplitTerminalContainerView?
        integratedView.onMultiSelect = { selected in
            let split = SplitTerminalContainerView(frame: integratedView.frame, renderer: renderer, controllers: selected)
            split.onBackToIntegrated = {
                split.removeFromSuperview()
                contentView.addSubview(integratedView)
                integratedView.frame = contentView.bounds
                integratedView.viewDidMoveToWindow()
            }
            createdSplit = split
        }

        let layouts = try XCTUnwrap(reflectedWorkspaceLayouts(from: integratedView).first)
        let firstPoint = try XCTUnwrap(layouts.terminals.first?.thumbnail.center)
        let secondPoint = try XCTUnwrap(layouts.terminals.dropFirst().first?.thumbnail.center)
        integratedView.mouseDown(with: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: firstPoint, in: integratedView, window: window, modifiers: [.shift])))
        integratedView.mouseDown(with: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, point: secondPoint, in: integratedView, window: window, modifiers: [.shift])))
        integratedView.flagsChanged(with: try XCTUnwrap(makeFlagsEvent(window: window, modifiers: [])))

        let split = try XCTUnwrap(createdSplit)
        integratedView.removeFromSuperview()
        contentView.addSubview(split)
        split.frame = contentView.bounds
        split.layoutSubtreeIfNeeded()

        window.testBackingScaleFactor = 2.0
        let terminalViews = allSubviews(in: split).compactMap { $0 as? TerminalView }
        terminalViews.forEach { $0.viewDidChangeBackingProperties() }
        let splitRenderView = try XCTUnwrap(allSubviews(in: split).first(where: { $0 is SplitRenderView }) as? SplitRenderView)
        splitRenderView.viewDidChangeBackingProperties()
        renderFrame(for: splitRenderView)

        XCTAssertEqual(splitRenderView.layer?.contentsScale, 2.0)
        XCTAssertTrue(terminalViews.allSatisfy { $0.renderer?.glyphAtlas.scaleFactor == 2.0 })

        guard let scrollView = allSubviews(in: split).first(where: { $0 is TerminalScrollView }) as? TerminalScrollView else {
            XCTFail("TerminalScrollView missing")
            return
        }
        let backEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "`",
            charactersIgnoringModifiers: "`",
            isARepeat: false,
            keyCode: 50
        ))
        XCTAssertTrue(scrollView.performKeyEquivalent(with: backEvent))
        renderFrame(for: integratedView)
        let overviewDrawableSizeAtScale2 = integratedView.drawableSize

        window.testBackingScaleFactor = 1.5
        integratedView.viewDidChangeBackingProperties()
        renderFrame(for: integratedView)
        XCTAssertEqual(renderer.glyphAtlas.scaleFactor, 1.5)
        XCTAssertGreaterThan(integratedView.drawableSize.width, 0)
        XCTAssertGreaterThan(integratedView.drawableSize.height, 0)
        XCTAssertLessThan(integratedView.drawableSize.width, overviewDrawableSizeAtScale2.width)
        XCTAssertLessThan(integratedView.drawableSize.height, overviewDrawableSizeAtScale2.height)
    }

    private func allSubviews(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { allSubviews(in: $0) }
    }

    private func findSubview(in view: NSView?, matching predicate: (NSView) -> Bool) -> NSView? {
        allSubviews(in: view).first(where: predicate)
    }

    private func renderFrame(for view: MTKView) {
        view.displayIfNeeded()
        if let terminalView = view as? TerminalView {
            terminalView.draw(in: terminalView)
        } else if let splitRenderView = view as? SplitRenderView {
            splitRenderView.draw(in: splitRenderView)
        } else if let integratedView = view as? IntegratedView {
            integratedView.draw(in: integratedView)
        } else {
            view.draw()
        }
        drainMainQueue(testCase: self)
    }

    private func makeMouseEvent(type: NSEvent.EventType, point: NSPoint, in view: NSView, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: view.convert(point, to: nil),
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    private func makeFlagsEvent(window: NSWindow, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 56
        )
    }

    private func reflectedWorkspaceLayouts(from view: IntegratedView) -> [ReflectedWorkspaceLayout] {
        if let rawLayouts = mirroredChildValue(named: "cachedWorkspaceLayouts", in: view) {
            let reflected = Mirror(reflecting: rawLayouts).children.compactMap { child in
                reflectWorkspaceLayout(child.value)
            }
            if !reflected.isEmpty {
                return reflected
            }
        }

        guard let manager: TerminalManager = mirroredChild(named: "manager", in: view),
              let explicitWorkspaceNames: [String] = mirroredChild(named: "explicitWorkspaceNames", in: view) else {
            return []
        }
        return expectedWorkspaceLayouts(
            bounds: view.bounds,
            terminals: manager.terminals,
            explicitWorkspaceNames: explicitWorkspaceNames
        )
    }

    private func reflectedAddWorkspaceButtonFrame(from view: IntegratedView) -> NSRect? {
        mirroredChild(named: "addWorkspaceButtonFrame", in: view)
    }

    private func reflectedVisibleWorkspaceLayouts(from view: IntegratedView) -> [ReflectedWorkspaceLayout] {
        guard let rawLayouts = mirroredChildValue(named: "cachedVisibleWorkspaceLayouts", in: view) else {
            return []
        }
        return Mirror(reflecting: rawLayouts).children.compactMap { child in
            reflectWorkspaceLayout(child.value)
        }
    }

    private func expectedWorkspaceLayouts(
        bounds: NSRect,
        terminals: [TerminalController],
        explicitWorkspaceNames: [String]
    ) -> [ReflectedWorkspaceLayout] {
        struct WorkspaceSection {
            let name: String
            let terminals: [TerminalController]
        }

        let grouped = Dictionary(grouping: terminals) { controller in
            let name = controller.sessionSnapshot.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Uncategorized" : name
        }
        let explicit = explicitWorkspaceNames.map {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Uncategorized" : trimmed
        }
        var orderedNames: [String] = []
        var seen = Set<String>()
        for name in explicit where !seen.contains(name) {
            seen.insert(name)
            orderedNames.append(name)
        }
        for controller in terminals {
            let trimmed = controller.sessionSnapshot.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "Uncategorized" : trimmed
            if !seen.contains(name) {
                seen.insert(name)
                orderedNames.append(name)
            }
        }
        let sections = orderedNames.map { WorkspaceSection(name: $0, terminals: grouped[$0] ?? []) }
        guard !sections.isEmpty else { return [] }

        let outerPad: CGFloat = 16
        let innerPad: CGFloat = 12
        let headerHeight: CGFloat = 28
        let titleBarHeight: CGFloat = 24
        let aspect: CGFloat = 320.0 / 240.0
        let maxWidth: CGFloat = 320
        let minWidth: CGFloat = 80

        let fullContentWidth = bounds.width - outerPad * 2 - innerPad * 2
        let maxCellWidth = maxWidth + innerPad
        let fitCols = max(1, Int(ceil(fullContentWidth / maxCellWidth)))
        let thumbWidth = max(minWidth, min(maxWidth, (fullContentWidth - innerPad * CGFloat(fitCols)) / CGFloat(fitCols)))
        let cellWidth = thumbWidth + innerPad

        struct RowItem {
            let sectionIndex: Int
            let naturalWidth: CGFloat
        }
        var rows: [[RowItem]] = []
        var currentRow: [RowItem] = []
        var currentRowWidth: CGFloat = outerPad

        for (index, section) in sections.enumerated() {
            let terminalCount = max(section.terminals.count, 1)
            let gridCols = Int(ceil(sqrt(Double(terminalCount))))
            let naturalWidth = CGFloat(gridCols) * cellWidth + innerPad * 2
            let neededWidth = currentRowWidth + naturalWidth + outerPad
            if !currentRow.isEmpty, neededWidth > bounds.width {
                rows.append(currentRow)
                currentRow = []
                currentRowWidth = outerPad
            }
            currentRow.append(RowItem(sectionIndex: index, naturalWidth: naturalWidth))
            currentRowWidth += naturalWidth + outerPad
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        func actualGrid(terminalCount: Int, workspaceWidth: CGFloat) -> (cols: Int, rows: Int, thumbW: CGFloat, thumbH: CGFloat) {
            let workspaceContentWidth = workspaceWidth - innerPad * 2
            let minCellWidth = minWidth + innerPad
            let maxFitCols = max(1, Int(floor(workspaceContentWidth / minCellWidth)))
            let cols = max(1, min(terminalCount, maxFitCols))
            let tw = max(minWidth, min(maxWidth, (workspaceContentWidth - innerPad * CGFloat(cols)) / CGFloat(cols)))
            let th = tw / aspect
            let rows = Int(ceil(Double(terminalCount) / Double(cols)))
            return (cols, rows, tw, th)
        }

        var rowHeights: [CGFloat] = []
        for row in rows {
            let totalNatural = row.map(\.naturalWidth).reduce(0, +)
            let totalPad = outerPad * CGFloat(row.count + 1)
            let availableWidth = bounds.width - totalPad
            var maxContentHeight: CGFloat = 0
            for item in row {
                let workspaceWidth = totalNatural > 0
                    ? availableWidth * (item.naturalWidth / totalNatural)
                    : availableWidth / CGFloat(row.count)
                let terminalCount = max(sections[item.sectionIndex].terminals.count, 1)
                let grid = actualGrid(terminalCount: terminalCount, workspaceWidth: workspaceWidth)
                let workspaceCellHeight = grid.thumbH + titleBarHeight + innerPad
                maxContentHeight = max(maxContentHeight, CGFloat(grid.rows) * workspaceCellHeight)
            }
            rowHeights.append(max(headerHeight + innerPad * 1.5 + maxContentHeight + innerPad, 140))
        }

        var layouts: [ReflectedWorkspaceLayout] = []
        var currentY = outerPad
        for (rowIndex, row) in rows.enumerated() {
            let rowHeight = rowHeights[rowIndex]
            let totalNaturalWidth = row.map(\.naturalWidth).reduce(0, +)
            let totalPadding = outerPad * CGFloat(row.count + 1)
            let availableForWorkspaces = bounds.width - totalPadding
            var currentX = outerPad

            for item in row {
                let section = sections[item.sectionIndex]
                let workspaceWidth = totalNaturalWidth > 0
                    ? availableForWorkspaces * (item.naturalWidth / totalNaturalWidth)
                    : availableForWorkspaces / CGFloat(row.count)
                let frame = NSRect(x: currentX, y: currentY, width: workspaceWidth, height: rowHeight)
                let headerFrame = NSRect(
                    x: frame.minX + innerPad,
                    y: frame.minY + innerPad / 2,
                    width: frame.width - innerPad * 2,
                    height: headerHeight
                )
                let terminalCount = max(section.terminals.count, 1)
                let grid = actualGrid(terminalCount: terminalCount, workspaceWidth: workspaceWidth)
                let workspaceCellWidth = grid.thumbW + innerPad
                let workspaceCellHeight = grid.thumbH + titleBarHeight + innerPad
                let contentHeight = max(0, CGFloat(grid.rows) * workspaceCellHeight)
                let contentFrame = NSRect(
                    x: frame.minX + innerPad,
                    y: headerFrame.maxY + innerPad / 2,
                    width: frame.width - innerPad * 2,
                    height: contentHeight
                )
                let selectBtnH: CGFloat = titleBarHeight
                let selectAllW: CGFloat = 70
                let deselectW: CGFloat = 60
                let selectBtnY = frame.maxY - innerPad - selectBtnH
                let selectAllFrame = NSRect(
                    x: frame.maxX - innerPad - selectAllW,
                    y: selectBtnY,
                    width: selectAllW,
                    height: selectBtnH
                )
                let deselectFrame = NSRect(
                    x: selectAllFrame.minX - 4 - deselectW,
                    y: selectBtnY,
                    width: deselectW,
                    height: selectBtnH
                )

                let terminalLayouts: [ReflectedThumbnailLayout] = section.terminals.enumerated().map { index, controller in
                    let gridCol = index % grid.cols
                    let gridRow = index / grid.cols
                    let thumbX = contentFrame.minX + CGFloat(gridCol) * workspaceCellWidth + innerPad / 2
                    let thumbY = contentFrame.minY + CGFloat(gridRow) * workspaceCellHeight + innerPad / 2
                    let titleFrame = NSRect(x: thumbX, y: thumbY, width: grid.thumbW, height: titleBarHeight)
                    let thumbnailFrame = NSRect(x: thumbX, y: titleFrame.maxY, width: grid.thumbW, height: grid.thumbH)
                    return ReflectedThumbnailLayout(
                        controllerID: controller.id,
                        thumbnail: thumbnailFrame,
                        title: titleFrame,
                        workspace: section.name
                    )
                }

                layouts.append(ReflectedWorkspaceLayout(
                    name: section.name,
                    frame: frame,
                    headerFrame: headerFrame,
                    selectAllFrame: selectAllFrame,
                    deselectFrame: deselectFrame,
                    terminals: terminalLayouts
                ))
                currentX += workspaceWidth + outerPad
            }
            currentY += rowHeight + outerPad
        }

        return layouts
    }

    private func reflectWorkspaceLayout(_ raw: Any) -> ReflectedWorkspaceLayout? {
        guard let name: String = mirroredChild(named: "name", in: raw),
              let frame: NSRect = mirroredChild(named: "frame", in: raw),
              let headerFrame: NSRect = mirroredChild(named: "headerFrame", in: raw),
              let selectAllFrame: NSRect = mirroredChild(named: "selectAllFrame", in: raw),
              let deselectFrame: NSRect = mirroredChild(named: "deselectFrame", in: raw),
              let rawTerminals = mirroredChildValue(named: "terminals", in: raw) else {
            return nil
        }
        let terminals = Mirror(reflecting: rawTerminals).children.compactMap { child in
            reflectThumbnailLayout(child.value)
        }
        return ReflectedWorkspaceLayout(
            name: name,
            frame: frame,
            headerFrame: headerFrame,
            selectAllFrame: selectAllFrame,
            deselectFrame: deselectFrame,
            terminals: terminals
        )
    }

    private func reflectThumbnailLayout(_ raw: Any) -> ReflectedThumbnailLayout? {
        guard let controller: TerminalController = mirroredChild(named: "controller", in: raw),
              let thumbnail: NSRect = mirroredChild(named: "thumbnail", in: raw),
              let title: NSRect = mirroredChild(named: "title", in: raw),
              let workspace: String = mirroredChild(named: "workspace", in: raw) else {
            return nil
        }
        return ReflectedThumbnailLayout(controllerID: controller.id, thumbnail: thumbnail, title: title, workspace: workspace)
    }

    private func mirroredChild<T>(named name: String, in value: Any) -> T? {
        mirroredChildValue(named: name, in: value) as? T
    }

    private func mirroredChildValue(named name: String, in value: Any) -> Any? {
        Mirror(reflecting: value).children.first(where: { $0.label == name })?.value
    }

    private func withMockedAlertResponse(
        _ response: NSApplication.ModalResponse,
        testCase: () throws -> Void
    ) throws {
        AlertRunModalSwizzler.response = response
        AlertRunModalSwizzler.capturedAlert = nil
        let originalMethod = try XCTUnwrap(class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal)))
        let originalIMP = method_getImplementation(originalMethod)
        let block: @convention(block) (NSAlert) -> NSApplication.ModalResponse = { alert in
            AlertRunModalSwizzler.capturedAlert = alert
            return AlertRunModalSwizzler.response
        }
        let replacementIMP = imp_implementationWithBlock(block)
        method_setImplementation(originalMethod, replacementIMP)
        defer {
            method_setImplementation(originalMethod, originalIMP)
            imp_removeBlock(replacementIMP)
            AlertRunModalSwizzler.response = .abort
            AlertRunModalSwizzler.capturedAlert = nil
        }

        try testCase()
    }

    private func withIsolatedSettingsController<T>(
        _ body: (SettingsWindowController) throws -> T
    ) throws -> T {
        try withTemporaryHomeDirectory { _ in
            PtermDirectories.ensureDirectories()
            return try body(SettingsWindowController())
        }
    }

}

private struct ReflectedWorkspaceLayout {
    let name: String
    let frame: NSRect
    let headerFrame: NSRect
    let selectAllFrame: NSRect
    let deselectFrame: NSRect
    let terminals: [ReflectedThumbnailLayout]
}

private struct ReflectedThumbnailLayout {
    let controllerID: UUID
    let thumbnail: NSRect
    let title: NSRect
    let workspace: String
}

private final class TestScaleWindow: NSWindow {
    var testBackingScaleFactor: CGFloat = 2.0

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.titled], backing: .buffered, defer: false)
    }

    override var backingScaleFactor: CGFloat {
        testBackingScaleFactor
    }
}

private final class SaveSpy {
    private(set) var savedTexts: [String] = []

    func record(_ text: String) {
        savedTexts.append(text)
    }
}

private enum SaveFailure: Error {
    case expected
}

private final class AlertRunModalSwizzler: NSObject {
    static var response: NSApplication.ModalResponse = .abort
    static weak var capturedAlert: NSAlert?
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}

private final class TestDraggingInfo: NSObject, NSDraggingInfo {
    private let pasteboard: NSPasteboard
    private let location: NSPoint
    private var validItemsForDrop = 1
    private var formation: NSDraggingFormation = .default
    private var animates = false

    init(pasteboard: NSPasteboard, location: NSPoint) {
        self.pasteboard = pasteboard
        self.location = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { NSImage(size: NSSize(width: 1, height: 1)) }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation {
        get { formation }
        set { formation = newValue }
    }
    var animatesToDestination: Bool {
        get { animates }
        set { animates = newValue }
    }
    var numberOfValidItemsForDrop: Int {
        get { validItemsForDrop }
        set { validItemsForDrop = newValue }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey : Any] = [:], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
    func imageComponentsProvider() -> [NSDraggingImageComponent] { [] }
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { [] }
}

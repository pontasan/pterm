import AppKit
import CommonCrypto
import CryptoKit
import XCTest
@testable import PtermApp

final class AppInfrastructureTests: XCTestCase {
    func testPersistedWindowFrameRoundTripsNSRect() {
        let rect = NSRect(x: 10, y: 20, width: 640, height: 480)
        let persisted = PersistedWindowFrame(frame: rect)
        XCTAssertEqual(persisted.rect, rect)
    }

    func testPersistedSessionDecodingProvidesDefaultsForLegacyPayload() throws {
        let json = """
        {
          "windowFrame": { "x": 1, "y": 2, "width": 3, "height": 4 },
          "terminals": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PersistedSessionState.self, from: json)
        XCTAssertEqual(decoded.presentedMode, .integrated)
        XCTAssertEqual(decoded.splitTerminalIDs, [])
        XCTAssertEqual(decoded.workspaceNames, [])
        XCTAssertNil(decoded.focusedTerminalID)
    }

    func testAtomicFileWriterCreatesAndReplacesFilesWithPermissions() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("config.json")
            try AtomicFileWriter.write(Data("first".utf8), to: destination, permissions: 0o600)
            try AtomicFileWriter.write(Data("second".utf8), to: destination, permissions: 0o600)

            XCTAssertEqual(try String(contentsOf: destination), "second")
            XCTAssertEqual(try posixPermissions(of: destination) & 0o777, 0o600)
        }
    }

    func testAtomicFileWriterCreatesParentDirectoriesWithSecurePermissions() throws {
        try withTemporaryDirectory { directory in
            let nestedDir = directory.appendingPathComponent("a/b/c", isDirectory: true)
            let destination = nestedDir.appendingPathComponent("state.json")

            try AtomicFileWriter.write(Data("{}".utf8), to: destination, permissions: 0o600)

            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try posixPermissions(of: nestedDir) & 0o777, 0o700)
        }
    }

    func testFileNameSanitizerReplacesReservedCharactersAndFallsBackForBlankValues() {
        XCTAssertEqual(FileNameSanitizer.sanitize(" a/b:c\n", fallback: "fallback"), "a_b_c")
        XCTAssertEqual(FileNameSanitizer.sanitize("   ", fallback: "fallback"), "fallback")
    }

    func testSessionStoreReturnsNoneWhenNoSessionExistsAndCreatesCrashMarker() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            XCTAssertEqual(try store.prepareRestoreDecision(), .none)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("crash.marker").path))
        }
    }

    func testSessionStoreMarkCleanShutdownRemovesCrashMarker() throws {
        try withTemporaryDirectory { directory in
            let marker = directory.appendingPathComponent("crash.marker")
            try Data("x".utf8).write(to: marker)
            let store = SessionStore(directory: directory)
            try store.markCleanShutdown()
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testSessionStorePrepareRestoreDecisionThrowsForCorruptSession() throws {
        try withTemporaryDirectory { directory in
            let sessionURL = directory.appendingPathComponent("session.json")
            try Data("not-json".utf8).write(to: sessionURL)
            let store = SessionStore(directory: directory)
            XCTAssertThrowsError(try store.prepareRestoreDecision())
        }
    }

    func testSessionStoreTransitionsFromUncleanToCleanRestore() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            let state = PersistedSessionState(
                windowFrame: PersistedWindowFrame(frame: NSRect(x: 1, y: 2, width: 3, height: 4)),
                focusedTerminalID: UUID(),
                presentedMode: .split,
                splitTerminalIDs: [UUID()],
                workspaceNames: ["Main"],
                terminals: []
            )

            try store.save(state)
            _ = try store.prepareRestoreDecision()
            XCTAssertEqual(try store.prepareRestoreDecision(), .requireUserConfirmation(state))
            try store.markCleanShutdown()
            XCTAssertEqual(try store.prepareRestoreDecision(), .restore(state))
        }
    }

    func testSessionStoreSaveUsesSecurePermissions() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            try store.save(PersistedSessionState(
                windowFrame: PersistedWindowFrame(frame: .zero),
                focusedTerminalID: nil,
                presentedMode: .integrated,
                splitTerminalIDs: [],
                workspaceNames: [],
                terminals: []
            ))
            let sessionURL = directory.appendingPathComponent("session.json")
            XCTAssertEqual(try posixPermissions(of: sessionURL) & 0o777, 0o600)
        }
    }

    func testSessionStoreClearSessionIgnoresMissingDirectory() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("missing")
            let store = SessionStore(directory: target)
            try store.clearSession()
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testSessionStoreClearSessionRemovesPersistedFiles() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            try store.save(PersistedSessionState(
                windowFrame: PersistedWindowFrame(frame: .zero),
                focusedTerminalID: nil,
                presentedMode: .integrated,
                splitTerminalIDs: [],
                workspaceNames: [],
                terminals: []
            ))
            try store.clearSession()
            let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testAppNoteStoreLoadNoteReturnsNilWhenEncryptedNoteDoesNotExist() throws {
        try withTemporaryDirectory { directory in
            let store = AppNoteStore(rootDirectory: directory)
            XCTAssertNil(try store.loadNote())
        }
    }

    func testAppNoteStoreImportEncryptionKeyRejectsInvalidLengthBeforeKeychainMutation() {
        let store = AppNoteStore(rootDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))

        XCTAssertThrowsError(try store.importEncryptionKey(Data(repeating: 0xAA, count: 31))) { error in
            guard case AppNoteError.invalidKeyLength = error else {
                XCTFail("Expected invalidKeyLength, got \(error)")
                return
            }
        }
    }

    func testAppNoteStoreLoadNoteRejectsCorruptEncryptedPayload() throws {
        try withTemporaryDirectory { directory in
            try Data("not-an-encrypted-note".utf8).write(to: directory.appendingPathComponent("note.enc"))
            let store = AppNoteStore(rootDirectory: directory)

            XCTAssertThrowsError(try store.loadNote()) { error in
                guard case AppNoteError.invalidFormat = error else {
                    return XCTFail("Expected invalidFormat, got \(error)")
                }
            }
        }
    }

    func testAppNoteStoreLoadNoteRejectsDecryptedPayloadWithInvalidUTF8() throws {
        try withTemporaryDirectory { directory in
            let store = AppNoteStore(rootDirectory: directory)
            let originalKey = try store.exportEncryptionKey()
            defer { try? store.importEncryptionKey(originalKey) }

            let importedKey = Data(repeating: 0x44, count: 32)
            try store.importEncryptionKey(importedKey)
            let ciphertext = try encryptedNotePayloadForTest(plaintext: Data([0xFF]), key: importedKey)
            try ciphertext.write(to: directory.appendingPathComponent("note.enc"))

            XCTAssertThrowsError(try store.loadNote()) { error in
                guard case AppNoteError.invalidFormat = error else {
                    return XCTFail("Expected invalidFormat, got \(error)")
                }
            }
        }
    }

    func testAppNoteStoreImportEncryptionKeyRefreshesCachedKeyImmediately() throws {
        try withTemporaryDirectory { directory in
            let store = AppNoteStore(rootDirectory: directory)
            let originalKey = try store.exportEncryptionKey()
            defer { try? store.importEncryptionKey(originalKey) }

            let importedKey = Data(repeating: 0x55, count: 32)
            XCTAssertNotEqual(originalKey, importedKey)

            try store.importEncryptionKey(importedKey)

            XCTAssertEqual(try store.exportEncryptionKey(), importedKey)
        }
    }

    func testShortcutParserParsesConfiguredBindingsAndFallsBackOnInvalidValues() {
        let shortcuts = ShortcutParser.parseMap([
            "find_previous": "Cmd+Shift+G",
            "zoom_in": "Cmd++",
            "copy": "Shift+X"
        ])

        let findPrevious = shortcuts.binding(for: .findPrevious).primary
        XCTAssertEqual(findPrevious.modifiers, [.command, .shift])
        XCTAssertEqual(findPrevious.menuKeyEquivalent, "g")

        let zoomIn = shortcuts.binding(for: .zoomIn).primary
        XCTAssertEqual(zoomIn.modifiers, [.command, .shift])
        XCTAssertEqual(zoomIn.menuKeyEquivalent, "=")

        let copy = shortcuts.binding(for: .copy).primary
        XCTAssertEqual(copy.modifiers, [.command])
        XCTAssertEqual(copy.menuKeyEquivalent, "c")
    }

    func testShortcutParserSupportsNamedSpecialKeys() {
        let shortcuts = ShortcutParser.parseMap([
            "back_to_integrated": "Cmd+Esc",
            "focus_previous_terminal": "Cmd+Left",
            "focus_next_terminal": "Cmd+Right"
        ])

        XCTAssertEqual(shortcuts.binding(for: .backToIntegrated).primary.menuKeyEquivalent, "\u{1B}")
        XCTAssertEqual(shortcuts.binding(for: .focusPreviousTerminal).primary.menuKeyEquivalent,
                       String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        XCTAssertEqual(shortcuts.binding(for: .focusNextTerminal).primary.menuKeyEquivalent,
                       String(UnicodeScalar(NSRightArrowFunctionKey)!))
    }

    func testShortcutConfigurationZoomInMatchesPrimaryAndAlternateBindings() {
        let binding = ShortcutConfiguration.default.binding(for: .zoomIn)
        XCTAssertEqual(binding.alternates.count, 1)

        let primaryEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "=",
            charactersIgnoringModifiers: "=",
            isARepeat: false,
            keyCode: 24
        )!
        let alternateEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "+",
            charactersIgnoringModifiers: "=",
            isARepeat: false,
            keyCode: 24
        )!

        XCTAssertTrue(binding.matches(primaryEvent))
        XCTAssertTrue(binding.matches(alternateEvent))
    }

    func testShortcutParserRejectsBindingsWithoutCommandModifier() {
        let parsed = ShortcutParser.parseMap([
            "copy": "Shift+C"
        ])
        XCTAssertEqual(parsed.binding(for: .copy).primary.menuKeyEquivalent, "c")
        XCTAssertEqual(parsed.binding(for: .copy).primary.modifiers, [.command])
    }

    func testShortcutActionsExposeSelectors() {
        for action in ShortcutAction.allCases {
            XCTAssertNotNil(action.appDelegateSelector)
        }
    }

    func testKeyboardShortcutMenuKeyEquivalentMatchesSpecialKeyCodes() {
        let backtick = KeyboardShortcut(modifiers: [.command], trigger: .keyCode(50))
        let escape = KeyboardShortcut(modifiers: [.command], trigger: .keyCode(53))
        let left = KeyboardShortcut(modifiers: [.command], trigger: .keyCode(123))
        let right = KeyboardShortcut(modifiers: [.command], trigger: .keyCode(124))

        XCTAssertEqual(backtick.menuKeyEquivalent, "`")
        XCTAssertEqual(escape.menuKeyEquivalent, "\u{1B}")
        XCTAssertEqual(left.menuKeyEquivalent, String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        XCTAssertEqual(right.menuKeyEquivalent, String(UnicodeScalar(NSRightArrowFunctionKey)!))
    }

    @MainActor
    func testKeyboardShortcutMatchesCharacterCaseInsensitively() {
        let shortcut = KeyboardShortcut(modifiers: [.command], trigger: .character("c"))
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .capsLock],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "C",
            charactersIgnoringModifiers: "C",
            isARepeat: false,
            keyCode: 8
        )

        XCTAssertEqual(shortcut.matches(event!), true)
    }

    func testTerminfoResolverRejectsInvalidConfiguredName() {
        let resolved = TerminfoResolver.resolveConfiguredTerm("../bad name")
        XCTAssertNotEqual(resolved, "../bad name")
        XCTAssertFalse(resolved.isEmpty)
    }

    func testSingleInstanceLockRejectsSecondOwnerUntilRelease() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("lock")
            let first = SingleInstanceLock(lockURL: lockURL)
            let second = SingleInstanceLock(lockURL: lockURL)

            XCTAssertTrue(try first.acquireOrActivateExisting())
            XCTAssertFalse(try second.acquireOrActivateExisting())

            first.release()

            XCTAssertTrue(try second.acquireOrActivateExisting())
            second.release()
        }
    }

    func testSingleInstanceLockCreatesLockFileWithSecurePermissions() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("lock")
            let lock = SingleInstanceLock(lockURL: lockURL)
            XCTAssertTrue(try lock.acquireOrActivateExisting())
            defer { lock.release() }
            XCTAssertEqual(try posixPermissions(of: lockURL) & 0o777, 0o600)
        }
    }

    func testSingleInstanceLockReleaseIsIdempotent() throws {
        try withTemporaryDirectory { directory in
            let lock = SingleInstanceLock(lockURL: directory.appendingPathComponent("lock"))
            XCTAssertTrue(try lock.acquireOrActivateExisting())
            lock.release()
            lock.release()
        }
    }

    func testReadWriteLockSerializesWritesAgainstConcurrentReads() {
        let lock = ReadWriteLock()
        let queue = DispatchQueue(label: "lock-test", attributes: .concurrent)
        let group = DispatchGroup()
        var values: [Int] = []

        for readValue in 0..<10 {
            group.enter()
            queue.async {
                lock.withReadLock {
                    _ = values.count
                }
                group.leave()
            }

            group.enter()
            queue.async {
                lock.withWriteLock {
                    values.append(readValue)
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(values.sorted(), Array(0..<10))
    }

    func testClipboardFileStoreQuotesPathsAndDeletesExpiredFiles() throws {
        try withTemporaryDirectory { directory in
            let oldDate = Date(timeIntervalSince1970: 1000)
            let currentDate = oldDate.addingTimeInterval(25 * 60 * 60)
            let store = ClipboardFileStore(rootDirectory: directory, nowProvider: { currentDate })
            let file = directory.appendingPathComponent("old.bin")
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)

            XCTAssertEqual(store.shellQuotedPath("/tmp/has ' quote"), "'/tmp/has '\\'' quote'")
            try store.cleanupExpiredFiles()
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @MainActor
    func testClipboardFileStoreImportsBinaryPasteboardPayload() throws {
        try withTemporaryDirectory { directory in
            let store = ClipboardFileStore(rootDirectory: directory)
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.clearContents()

            let item = NSPasteboardItem()
            item.setData(Data([0x01, 0x02, 0x03]), forType: .png)
            pasteboard.writeObjects([item])

            let result = try XCTUnwrap(store.importFromPasteboard(pasteboard))
            XCTAssertEqual(result.createdFiles.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.createdFiles[0].path))
            XCTAssertTrue(result.textToPaste.contains(result.createdFiles[0].lastPathComponent))
            XCTAssertEqual(try posixPermissions(of: result.createdFiles[0]) & 0o777, 0o600)
        }
    }

    @MainActor
    func testClipboardFileStoreImportsFileURLsAndQuotesStoredDestinationPath() throws {
        try withTemporaryDirectory { directory in
            let externalRoot = directory.appendingPathComponent("external")
            try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
            let source = externalRoot.appendingPathComponent("hello world.txt")
            try Data("a".utf8).write(to: source)

            let managedRoot = directory.appendingPathComponent("managed files'root")
            let store = ClipboardFileStore(rootDirectory: managedRoot)
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([source as NSURL]))

            let result = try XCTUnwrap(store.importFromPasteboard(pasteboard))
            XCTAssertEqual(result.createdFiles.count, 1)
            XCTAssertTrue(result.textToPaste.contains("'\\''"))
            XCTAssertTrue(result.textToPaste.hasPrefix("'"))
            XCTAssertTrue(result.textToPaste.hasSuffix("'"))

            for created in result.createdFiles {
                XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
                XCTAssertEqual(try posixPermissions(of: created) & 0o777, 0o600)
                XCTAssertEqual(created.deletingLastPathComponent().lastPathComponent, "managed files'root")
            }
        }
    }

    func testClipboardFileStoreCleanupCreatesManagedDirectoryWithSecurePermissions() throws {
        try withTemporaryDirectory { directory in
            let managed = directory.appendingPathComponent("managed")
            let store = ClipboardFileStore(rootDirectory: managed)

            try store.cleanupExpiredFiles()

            XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path))
            XCTAssertEqual(try posixPermissions(of: managed) & 0o777, 0o700)
        }
    }

    func testClipboardFileStoreRejectsDeletingOutsideManagedRoot() throws {
        try withTemporaryDirectory { directory in
            let store = ClipboardFileStore(rootDirectory: directory)
            let outside = directory.deletingLastPathComponent().appendingPathComponent("outside.txt")
            XCTAssertThrowsError(try store.deleteStoredFile(at: outside))
        }
    }

    func testClipboardFileStoreDeleteAllStoredFilesRemovesManagedContents() throws {
        try withTemporaryDirectory { directory in
            let store = ClipboardFileStore(rootDirectory: directory)
            let first = directory.appendingPathComponent("a.bin")
            let second = directory.appendingPathComponent("b.bin")
            try Data([0x01]).write(to: first)
            try Data([0x02]).write(to: second)

            try store.deleteAllStoredFiles()

            let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testClipboardCleanupServiceDeletesExpiredFilesOnSchedule() throws {
        try withTemporaryDirectory { directory in
            let expiredDate = Date(timeIntervalSince1970: 1000)
            let now = expiredDate.addingTimeInterval(25 * 60 * 60)
            let store = ClipboardFileStore(rootDirectory: directory, nowProvider: { now })
            let service = ClipboardCleanupService(fileStore: store, interval: 0.05)
            let stale = directory.appendingPathComponent("stale.bin")
            try Data([0xFF]).write(to: stale)
            try FileManager.default.setAttributes([.modificationDate: expiredDate], ofItemAtPath: stale.path)

            service.start()
            defer { service.stop() }

            let deadline = Date().addingTimeInterval(1.0)
            while FileManager.default.fileExists(atPath: stale.path) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }

            XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        }
    }

    func testAuditLoggerWritesPlaintextHeaderAndEvents() throws {
        try withTemporaryDirectory { directory in
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                timeZoneIdentifier: "Asia/Tokyo",
                termEnv: "xterm-256color",
                workspaceNameProvider: { "Main/Workspace" },
                terminalNameProvider: { "tail -f" },
                sizeProvider: { (120, 30) },
                nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
            )

            logger.recordOutput(Data("$ ".utf8))
            logger.recordInput(Data("ls\r".utf8))
            logger.close()

            let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".cast") }
            XCTAssertEqual(files.count, 1)

            let contents = try String(contentsOf: directory.appendingPathComponent(files[0]))
            XCTAssertTrue(contents.contains("\"version\":2"))
            XCTAssertTrue(contents.contains("\"session_id\":\"00000000-0000-0000-0000-000000000001\""))
            XCTAssertTrue(contents.contains("$ "))
            XCTAssertTrue(contents.contains("ls"))
        }
    }

    func testAuditLoggerWritesAndDecryptsEncryptedFrames() throws {
        try withTemporaryDirectory { directory in
            let key = SymmetricKey(data: Data(repeating: 0x11, count: 32))
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                timeZoneIdentifier: "Asia/Tokyo",
                termEnv: "xterm-256color",
                encryptionEnabled: true,
                workspaceNameProvider: { "Main" },
                terminalNameProvider: { "secure" },
                sizeProvider: { (80, 24) },
                keyProvider: { key },
                nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
            )

            logger.recordOutput(Data("secret\n".utf8))
            logger.close()

            let castPath = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
                .first(where: { $0.hasSuffix(".cast") })
            let encrypted = try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(castPath)))
            let decrypted = try TerminalAuditLogger.decryptFile(encrypted, key: key)
            let text = String(decoding: decrypted, as: UTF8.self)
            XCTAssertTrue(text.contains("secret"))
            XCTAssertTrue(text.contains("\"version\":2"))
        }
    }

    func testAuditLoggerAppendsHMACLineEveryHundredEvents() throws {
        try withTemporaryDirectory { directory in
            let key = SymmetricKey(data: Data(repeating: 0x22, count: 32))
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                timeZoneIdentifier: "Asia/Tokyo",
                termEnv: "xterm-256color",
                encryptionEnabled: true,
                workspaceNameProvider: { "Main" },
                terminalNameProvider: { "audit" },
                sizeProvider: { (80, 24) },
                keyProvider: { key },
                nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
            )

            for _ in 0..<100 {
                logger.recordOutput(Data("x".utf8))
            }
            logger.close()

            let castPath = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
                .first(where: { $0.hasSuffix(".cast") })
            let encrypted = try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(castPath)))
            let decrypted = try TerminalAuditLogger.decryptFile(encrypted, key: key)
            let text = String(decoding: decrypted, as: UTF8.self)
            XCTAssertTrue(text.contains("\"h\""))
            XCTAssertTrue(text.contains("hmac-sha256:"))
        }
    }

    func testAuditLoggerFlushesBufferedHighFrequencyWritesOnClose() throws {
        try withTemporaryDirectory { directory in
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                timeZoneIdentifier: "Asia/Tokyo",
                termEnv: "xterm-256color",
                workspaceNameProvider: { "Perf" },
                terminalNameProvider: { "stress" },
                sizeProvider: { (80, 24) },
                nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
            )

            for index in 0..<400 {
                logger.recordOutput(Data("line-\(index)\n".utf8))
            }
            logger.close()

            let castPath = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
                .first(where: { $0.hasSuffix(".cast") })
            let contents = try String(contentsOf: directory.appendingPathComponent(try XCTUnwrap(castPath)))
            XCTAssertTrue(contents.contains("line-0"))
            XCTAssertTrue(contents.contains("line-399"))
        }
    }

    func testAuditLoggerConcurrentInputOutputWritersPersistLatestMarkers() throws {
        try withTemporaryDirectory { directory in
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                timeZoneIdentifier: "Asia/Tokyo",
                termEnv: "xterm-256color",
                workspaceNameProvider: { "Main" },
                terminalNameProvider: { "tty" },
                sizeProvider: { (80, 24) },
                nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
            )

            let group = DispatchGroup()
            let queue = DispatchQueue(label: "audit-concurrent-writers", attributes: .concurrent)
            for index in 0..<200 {
                group.enter()
                queue.async {
                    logger.recordInput(Data("in-\(index)\n".utf8))
                    logger.recordOutput(Data("out-\(index)\n".utf8))
                    group.leave()
                }
            }

            XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
            logger.close()

            let castPath = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
                .first(where: { $0.hasSuffix(".cast") })
            let contents = try String(contentsOf: directory.appendingPathComponent(try XCTUnwrap(castPath)))
            XCTAssertTrue(contents.contains("in-0"))
            XCTAssertTrue(contents.contains("out-199"))
        }
    }

    func testAuditLoggerDecryptFileRejectsCorruptPayload() {
        let key = SymmetricKey(data: Data(repeating: 0x33, count: 32))
        XCTAssertThrowsError(try TerminalAuditLogger.decryptFile(Data("bad".utf8), key: key))
    }

    func testAuditLoggerCleanupWithNilRetentionKeepsExistingDirectories() throws {
        try withTemporaryDirectory { directory in
            let existing = directory.appendingPathComponent("2025-03-01")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(),
                termEnv: "xterm-256color",
                workspaceNameProvider: { "Main" },
                terminalNameProvider: { "tail" },
                sizeProvider: { (80, 24) }
            )

            try logger.cleanupExpiredLogs(retentionDays: nil)
            XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
        }
    }

    func testAuditLoggerCleanupIgnoresNonDateDirectories() throws {
        try withTemporaryDirectory { directory in
            let existing = directory.appendingPathComponent("not-a-date")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(),
                termEnv: "xterm-256color",
                workspaceNameProvider: { "Main" },
                terminalNameProvider: { "tail" },
                sizeProvider: { (80, 24) },
                nowProvider: { Date(timeIntervalSince1970: 1_741_737_600) }
            )

            try logger.cleanupExpiredLogs(retentionDays: 7)
            XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
        }
    }

    func testAuditLoggerCleanupRetentionZeroRemovesPastDateDirectories() throws {
        try withTemporaryDirectory { directory in
            let oldDir = directory.appendingPathComponent("2025-03-11")
            try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(),
                timeZoneIdentifier: "Asia/Tokyo",
                termEnv: "xterm-256color",
                workspaceNameProvider: { "Main" },
                terminalNameProvider: { "tail" },
                sizeProvider: { (80, 24) },
                nowProvider: { Date(timeIntervalSince1970: 1_741_737_600) }
            )

            try logger.cleanupExpiredLogs(retentionDays: 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path))
        }
    }

    func testAuditLoggerCleanupExpiredLogsRemovesOldDirectoriesOnly() throws {
        try withTemporaryDirectory { directory in
            let oldDir = directory.appendingPathComponent("2025-03-01")
            let keepDir = directory.appendingPathComponent("2025-03-12")
            try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: keepDir, withIntermediateDirectories: true)

            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(),
                timeZoneIdentifier: "Asia/Tokyo",
                termEnv: "xterm-256color",
                workspaceNameProvider: { "Main" },
                terminalNameProvider: { "tail" },
                sizeProvider: { (80, 24) },
                nowProvider: { Date(timeIntervalSince1970: 1_741_737_600) } // 2026-03-12 JST morning
            )
            try logger.cleanupExpiredLogs(retentionDays: 7)

            XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: keepDir.path))
        }
    }

    func testAuditKeyStoreCreatesAndReloadsStableKeyFile() throws {
        try withTemporaryDirectory { directory in
            let keyURL = directory.appendingPathComponent(".key")
            let first = try AuditKeyStore.loadOrCreateKey(url: keyURL)
            let second = try AuditKeyStore.loadOrCreateKey(url: keyURL)
            XCTAssertEqual(first.withUnsafeBytes { Data($0) }, second.withUnsafeBytes { Data($0) })
            XCTAssertEqual(try posixPermissions(of: keyURL) & 0o777, 0o400)
        }
    }

    func testAuditPathBuilderUsesProvidedTimeZone() {
        let date = Date(timeIntervalSince1970: 1_741_718_000) // boundary around JST day
        XCTAssertEqual(AuditPathBuilder.dayString(for: date, timeZoneIdentifier: "UTC"), "2025-03-11")
        XCTAssertEqual(AuditPathBuilder.dayString(for: date, timeZoneIdentifier: "Asia/Tokyo"), "2025-03-12")
    }

    func testAuditLoggerCloseIsSafeWithoutRecordedEvents() {
        let logger = TerminalAuditLogger(
            rootDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            sessionID: UUID(),
            termEnv: "xterm-256color",
            workspaceNameProvider: { "Main" },
            terminalNameProvider: { "idle" },
            sizeProvider: { (80, 24) }
        )

        logger.close()
        logger.close()
    }

    func testExportImportManagerNormalizesImportedPermissionsRecursively() throws {
        try withTemporaryDirectory { directory in
            let noteStore = AppNoteStore(rootDirectory: directory.appendingPathComponent("note-root"))
            let manager = PtermExportImportManager(
                noteStore: noteStore,
                fileManager: .default,
                configURL: directory.appendingPathComponent("config.json"),
                sessionsURL: directory.appendingPathComponent("sessions"),
                workspacesURL: directory.appendingPathComponent("workspaces"),
                auditURL: directory.appendingPathComponent("audit")
            )

            let sessions = directory.appendingPathComponent("sessions")
            let nested = sessions.appendingPathComponent("scrollback")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let regular = nested.appendingPathComponent("state.bin")
            let auditKey = directory.appendingPathComponent("audit").appendingPathComponent(".key")
            try FileManager.default.createDirectory(at: auditKey.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: regular)
            try Data("k".utf8).write(to: auditKey)

            try manager.normalizeImportedPermissions(for: [sessions, auditKey.deletingLastPathComponent()])

            XCTAssertEqual(try posixPermissions(of: sessions) & 0o777, 0o700)
            XCTAssertEqual(try posixPermissions(of: nested) & 0o777, 0o700)
            XCTAssertEqual(try posixPermissions(of: regular) & 0o777, 0o600)
            XCTAssertEqual(try posixPermissions(of: auditKey) & 0o777, 0o400)
        }
    }

    func testExportImportManagerDefaultExportURLUsesExpectedPrefixAndSuffix() {
        let manager = PtermExportImportManager(noteStore: AppNoteStore(rootDirectory: URL(fileURLWithPath: NSTemporaryDirectory())))
        let fileName = manager.defaultExportURL().lastPathComponent
        XCTAssertTrue(fileName.hasPrefix("pterm-export-"))
        XCTAssertTrue(fileName.hasSuffix(".zip"))
    }

    func testExportImportManagerRequiresPasswordForExportAndImport() throws {
        try withTemporaryDirectory { directory in
            let manager = PtermExportImportManager(
                noteStore: AppNoteStore(rootDirectory: directory.appendingPathComponent("notes")),
                configURL: directory.appendingPathComponent("config.json"),
                sessionsURL: directory.appendingPathComponent("sessions"),
                workspacesURL: directory.appendingPathComponent("workspaces"),
                auditURL: directory.appendingPathComponent("audit")
            )
            let archiveURL = directory.appendingPathComponent("archive.zip")

            XCTAssertThrowsError(try manager.exportArchive(to: archiveURL, password: "")) { error in
                guard case PtermExportImportError.passwordRequired = error else {
                    return XCTFail("Expected passwordRequired, got \(error)")
                }
            }
            XCTAssertThrowsError(try manager.importArchive(from: archiveURL, password: "")) { error in
                guard case PtermExportImportError.passwordRequired = error else {
                    return XCTFail("Expected passwordRequired, got \(error)")
                }
            }
        }
    }

    func testExportImportManagerInspectArchiveReportsIncludedAndOverwrittenItems() throws {
        try withTemporaryDirectory { directory in
            let archiveRoot = directory.appendingPathComponent("payload")
            let archiveURL = directory.appendingPathComponent("archive.zip")
            let configURL = directory.appendingPathComponent("dest-config.json")
            let sessionsURL = directory.appendingPathComponent("dest-sessions")
            let workspacesURL = directory.appendingPathComponent("dest-workspaces")
            let auditURL = directory.appendingPathComponent("dest-audit")
            try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: archiveRoot.appendingPathComponent("config.json"))
            try FileManager.default.createDirectory(at: archiveRoot.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            try Data("k".utf8).write(to: archiveRoot.appendingPathComponent("keys.enc"))
            try Data("existing".utf8).write(to: configURL)
            try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", archiveRoot.path, archiveURL.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)

            let manager = PtermExportImportManager(
                noteStore: AppNoteStore(rootDirectory: directory.appendingPathComponent("notes")),
                configURL: configURL,
                sessionsURL: sessionsURL,
                workspacesURL: workspacesURL,
                auditURL: auditURL
            )

            let preview = try manager.inspectArchive(archiveURL)
            XCTAssertEqual(Set(preview.includedItems), Set(["config.json", "sessions/", "keys.enc"]))
            XCTAssertEqual(Set(preview.overwrittenItems), Set(["config.json", "sessions/"]))
        }
    }

    func testExportImportManagerInspectArchiveRejectsInvalidZipPayload() throws {
        try withTemporaryDirectory { directory in
            let archiveURL = directory.appendingPathComponent("invalid.zip")
            try Data("not-a-zip".utf8).write(to: archiveURL)
            let manager = PtermExportImportManager(
                noteStore: AppNoteStore(rootDirectory: directory.appendingPathComponent("notes")),
                configURL: directory.appendingPathComponent("config.json"),
                sessionsURL: directory.appendingPathComponent("sessions"),
                workspacesURL: directory.appendingPathComponent("workspaces"),
                auditURL: directory.appendingPathComponent("audit")
            )

            XCTAssertThrowsError(try manager.inspectArchive(archiveURL))
        }
    }

    func testExportImportManagerInspectArchiveRejectsSymbolicLinksInArchive() throws {
        try withTemporaryDirectory { directory in
            let archiveRoot = directory.appendingPathComponent("payload")
            let archiveURL = directory.appendingPathComponent("archive.zip")
            try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
            let symlinkURL = archiveRoot.appendingPathComponent("config.json")
            try FileManager.default.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: "/etc/passwd")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", archiveRoot.path, archiveURL.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)

            let manager = PtermExportImportManager(
                noteStore: AppNoteStore(rootDirectory: directory.appendingPathComponent("notes")),
                configURL: directory.appendingPathComponent("config.json"),
                sessionsURL: directory.appendingPathComponent("sessions"),
                workspacesURL: directory.appendingPathComponent("workspaces"),
                auditURL: directory.appendingPathComponent("audit")
            )

            XCTAssertThrowsError(try manager.inspectArchive(archiveURL)) { error in
                guard case let PtermExportImportError.unsafeArchiveEntry(path) = error else {
                    return XCTFail("Expected unsafeArchiveEntry, got \(error)")
                }
                XCTAssertEqual(path, "config.json")
            }
        }
    }

    func testExportImportManagerImportArchiveRejectsSymbolicLinksBeforeRestoringFiles() throws {
        try withTemporaryDirectory { directory in
            let archiveRoot = directory.appendingPathComponent("payload")
            let archiveURL = directory.appendingPathComponent("archive.zip")
            let configURL = directory.appendingPathComponent("dest-config.json")
            try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
            try Data("PTE1invalid".utf8).write(to: archiveRoot.appendingPathComponent("keys.enc"))
            let symlinkURL = archiveRoot.appendingPathComponent("sessions")
            try FileManager.default.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: "/tmp")
            try Data("existing".utf8).write(to: configURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", archiveRoot.path, archiveURL.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)

            let manager = PtermExportImportManager(
                noteStore: AppNoteStore(rootDirectory: directory.appendingPathComponent("notes")),
                configURL: configURL,
                sessionsURL: directory.appendingPathComponent("sessions"),
                workspacesURL: directory.appendingPathComponent("workspaces"),
                auditURL: directory.appendingPathComponent("audit")
            )

            XCTAssertThrowsError(try manager.importArchive(from: archiveURL, password: "secret")) { error in
                guard case let PtermExportImportError.unsafeArchiveEntry(path) = error else {
                    return XCTFail("Expected unsafeArchiveEntry, got \(error)")
                }
                XCTAssertEqual(path, "sessions")
            }
            XCTAssertEqual(try String(contentsOf: configURL), "existing")
        }
    }

    @MainActor
    func testProcessMetricsMonitorEmitsSnapshotForEmptyPIDSet() {
        let monitor = ProcessMetricsMonitor(interval: 60)
        let expectation = expectation(description: "metrics-update")
        monitor.onUpdate = { snapshot in
            XCTAssertTrue(snapshot.cpuUsageByPID.isEmpty)
            XCTAssertTrue(snapshot.currentDirectoryByPID.isEmpty)
            XCTAssertTrue(snapshot.memoryByPID.isEmpty)
            XCTAssertGreaterThan(snapshot.appMemoryBytes, 0)
            expectation.fulfill()
        }

        monitor.start(pidsProvider: { [] })
        wait(for: [expectation], timeout: 1.0)
        monitor.stop()
    }

    @MainActor
    func testProcessMetricsMonitorCapturesCurrentDirectoryAndMemoryForLiveChildProcess() throws {
        try withTemporaryDirectory { directory in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.currentDirectoryURL = directory
            process.arguments = ["-c", "sleep 2"]
            try process.run()
            defer {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }

            let monitor = ProcessMetricsMonitor(interval: 60)
            let expectation = expectation(description: "metrics-update-live-child")
            monitor.onUpdate = { snapshot in
                guard let cwd = snapshot.currentDirectoryByPID[process.processIdentifier],
                      let memory = snapshot.memoryByPID[process.processIdentifier] else {
                    return
                }
                let resolvedCWD = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
                XCTAssertEqual(resolvedCWD, directory.resolvingSymlinksInPath().path)
                XCTAssertGreaterThan(memory, 0)
                expectation.fulfill()
            }

            monitor.start(pidsProvider: { [process.processIdentifier] })
            wait(for: [expectation], timeout: 1.0)
            monitor.stop()
        }
    }
}

private func encryptedNotePayloadForTest(plaintext: Data, key: Data) throws -> Data {
    let magic = Data("PTN1".utf8)
    let salt = Data(repeating: 0x11, count: 16)
    let iv = Data(repeating: 0x22, count: kCCBlockSizeAES128)
    var output = Data(count: plaintext.count + kCCBlockSizeAES128)
    let outputCapacity = output.count
    var outLength = 0

    let status = output.withUnsafeMutableBytes { outputBytes in
        plaintext.withUnsafeBytes { inputBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count,
                        ivBytes.baseAddress,
                        inputBytes.baseAddress, plaintext.count,
                        outputBytes.baseAddress, outputCapacity,
                        &outLength
                    )
                }
            }
        }
    }

    guard status == kCCSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    output.removeSubrange(outLength..<output.count)
    return magic + salt + iv + output
}

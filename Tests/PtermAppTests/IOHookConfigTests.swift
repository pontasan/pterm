import XCTest
@testable import PtermApp

final class IOHookConfigTests: XCTestCase {

    // MARK: - Default

    func testDefaultConfigIsDisabledWithNoHooks() {
        let config = IOHookConfiguration.default
        XCTAssertFalse(config.enabled)
        XCTAssertTrue(config.hooks.isEmpty)
    }

    // MARK: - Master Switch

    func testMasterSwitchParsedFromRoot() {
        let root: [String: Any] = ["io_hooks_enabled": true]
        let config = IOHookConfiguration.parse(from: root)
        XCTAssertTrue(config.enabled)
        XCTAssertTrue(config.hooks.isEmpty)
    }

    func testMasterSwitchDefaultsToFalse() {
        let config = IOHookConfiguration.parse(from: [:])
        XCTAssertFalse(config.enabled)
    }

    func testMasterSwitchOffPreservesHooksArray() {
        let root: [String: Any] = [
            "io_hooks_enabled": false,
            "io_hooks": [
                ["name": "test", "target": "output", "command": "/bin/cat"]
            ]
        ]
        let config = IOHookConfiguration.parse(from: root)
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.hooks.count, 1)
    }

    // MARK: - Full Entry Parsing

    func testParseCompleteHookEntry() {
        let root: [String: Any] = [
            "io_hooks_enabled": true,
            "io_hooks": [
                [
                    "enabled": true,
                    "name": "LLM logger",
                    "target": "output",
                    "buffering": "idle",
                    "idle_ms": 300,
                    "buffer_size": 131072,
                    "command": "/bin/sh -c 'cat >> ~/log'",
                    "process_match": "^claude$",
                    "include_children": true
                ]
            ]
        ]
        let config = IOHookConfiguration.parse(from: root)
        XCTAssertEqual(config.hooks.count, 1)

        let hook = config.hooks[0]
        XCTAssertTrue(hook.enabled)
        XCTAssertEqual(hook.name, "LLM logger")
        XCTAssertEqual(hook.target, .output)
        XCTAssertEqual(hook.buffering, .idle)
        XCTAssertEqual(hook.idleMs, 300)
        XCTAssertEqual(hook.bufferSize, 131072)
        XCTAssertEqual(hook.command, "/bin/sh -c 'cat >> ~/log'")
        XCTAssertEqual(hook.processMatch, "^claude$")
        XCTAssertNotNil(hook.processMatchRegex)
        XCTAssertTrue(hook.includeChildren)
    }

    // MARK: - Defaults for Optional Fields

    func testOptionalFieldsUseDefaults() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "minimal", "target": "output", "command": "/bin/cat"]
            ]
        ]
        let config = IOHookConfiguration.parse(from: root)
        XCTAssertEqual(config.hooks.count, 1)

        let hook = config.hooks[0]
        XCTAssertTrue(hook.enabled)  // default true
        XCTAssertEqual(hook.buffering, .line)  // default line
        XCTAssertEqual(hook.idleMs, IOHookEntry.defaultIdleMs)
        XCTAssertEqual(hook.bufferSize, IOHookEntry.defaultBufferSize)
        XCTAssertNil(hook.processMatch)
        XCTAssertNil(hook.processMatchRegex)
        XCTAssertFalse(hook.includeChildren)
    }

    // MARK: - Target

    func testStdinTarget() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "input", "target": "stdin", "command": "/bin/cat"]
            ]
        ]
        let hook = IOHookConfiguration.parse(from: root).hooks[0]
        XCTAssertEqual(hook.target, .stdin)
    }

    func testInvalidTargetSkipsEntry() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "bad", "target": "stderr", "command": "/bin/cat"]
            ]
        ]
        let config = IOHookConfiguration.parse(from: root)
        XCTAssertTrue(config.hooks.isEmpty)
    }

    // MARK: - Buffering Modes

    func testAllBufferingModes() {
        for mode in ["immediate", "line", "idle"] {
            let root: [String: Any] = [
                "io_hooks": [
                    ["name": "test", "target": "output", "command": "/bin/cat", "buffering": mode]
                ]
            ]
            let hook = IOHookConfiguration.parse(from: root).hooks[0]
            XCTAssertEqual(hook.buffering.rawValue, mode)
        }
    }

    func testInvalidBufferingFallsBackToLine() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "test", "target": "output", "command": "/bin/cat", "buffering": "invalid"]
            ]
        ]
        let hook = IOHookConfiguration.parse(from: root).hooks[0]
        XCTAssertEqual(hook.buffering, .line)
    }

    // MARK: - idle_ms Clamping

    func testIdleMsClampedBelowMinimum() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "test", "target": "output", "command": "/bin/cat", "idle_ms": 0]
            ]
        ]
        let hook = IOHookConfiguration.parse(from: root).hooks[0]
        XCTAssertEqual(hook.idleMs, IOHookEntry.minIdleMs)
    }

    func testIdleMsClampedAboveMaximum() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "test", "target": "output", "command": "/bin/cat", "idle_ms": 99999]
            ]
        ]
        let hook = IOHookConfiguration.parse(from: root).hooks[0]
        XCTAssertEqual(hook.idleMs, IOHookEntry.maxIdleMs)
    }

    // MARK: - buffer_size Clamping

    func testBufferSizeClampedBelowMinimum() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "test", "target": "output", "command": "/bin/cat", "buffer_size": 100]
            ]
        ]
        let hook = IOHookConfiguration.parse(from: root).hooks[0]
        XCTAssertEqual(hook.bufferSize, IOHookEntry.minBufferSize)
    }

    func testBufferSizeClampedAboveMaximum() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "test", "target": "output", "command": "/bin/cat", "buffer_size": 999_999_999]
            ]
        ]
        let hook = IOHookConfiguration.parse(from: root).hooks[0]
        XCTAssertEqual(hook.bufferSize, IOHookEntry.maxBufferSize)
    }

    // MARK: - Validation: Required Fields

    func testMissingNameSkipsEntry() {
        let root: [String: Any] = [
            "io_hooks": [
                ["target": "output", "command": "/bin/cat"]
            ]
        ]
        XCTAssertTrue(IOHookConfiguration.parse(from: root).hooks.isEmpty)
    }

    func testEmptyNameSkipsEntry() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "", "target": "output", "command": "/bin/cat"]
            ]
        ]
        XCTAssertTrue(IOHookConfiguration.parse(from: root).hooks.isEmpty)
    }

    func testMissingCommandSkipsEntry() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "test", "target": "output"]
            ]
        ]
        XCTAssertTrue(IOHookConfiguration.parse(from: root).hooks.isEmpty)
    }

    func testEmptyCommandSkipsEntry() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "test", "target": "output", "command": ""]
            ]
        ]
        XCTAssertTrue(IOHookConfiguration.parse(from: root).hooks.isEmpty)
    }

    func testMissingTargetSkipsEntry() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "test", "command": "/bin/cat"]
            ]
        ]
        XCTAssertTrue(IOHookConfiguration.parse(from: root).hooks.isEmpty)
    }

    // MARK: - process_match Regex

    func testValidRegexCompiles() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "test", "target": "output", "command": "/bin/cat", "process_match": "^(claude|codex)$"]
            ]
        ]
        let hook = IOHookConfiguration.parse(from: root).hooks[0]
        XCTAssertNotNil(hook.processMatchRegex)
        XCTAssertEqual(hook.processMatch, "^(claude|codex)$")
    }

    func testInvalidRegexSkipsEntry() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "test", "target": "output", "command": "/bin/cat", "process_match": "[invalid"]
            ]
        ]
        XCTAssertTrue(IOHookConfiguration.parse(from: root).hooks.isEmpty)
    }

    func testNullProcessMatchMatchesAll() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "test", "target": "output", "command": "/bin/cat"]
            ]
        ]
        let hook = IOHookConfiguration.parse(from: root).hooks[0]
        XCTAssertNil(hook.processMatch)
        XCTAssertNil(hook.processMatchRegex)
    }

    // MARK: - Multiple Hooks

    func testMultipleHooksParsed() {
        let root: [String: Any] = [
            "io_hooks": [
                ["name": "hook1", "target": "output", "command": "/bin/cat"],
                ["name": "hook2", "target": "stdin", "command": "/usr/bin/tee /dev/null"],
                ["name": "bad", "target": "invalid", "command": "/bin/cat"]  // skipped
            ]
        ]
        let config = IOHookConfiguration.parse(from: root)
        XCTAssertEqual(config.hooks.count, 2)
        XCTAssertEqual(config.hooks[0].name, "hook1")
        XCTAssertEqual(config.hooks[1].name, "hook2")
    }

    // MARK: - Equatable

    func testEqualConfigurations() {
        let root: [String: Any] = [
            "io_hooks_enabled": true,
            "io_hooks": [
                ["name": "test", "target": "output", "command": "/bin/cat", "buffering": "immediate"]
            ]
        ]
        let a = IOHookConfiguration.parse(from: root)
        let b = IOHookConfiguration.parse(from: root)
        XCTAssertEqual(a, b)
    }

    // MARK: - Integration with PtermConfig

    func testPtermConfigLoadIncludesIOHooks() throws {
        try withTemporaryPtermConfig { configURL in
            let json: [String: Any] = [
                "io_hooks_enabled": true,
                "io_hooks": [
                    ["name": "test", "target": "output", "command": "/bin/cat"]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: json)
            try data.write(to: configURL)

            let config = PtermConfigStore.load(from: configURL)
            XCTAssertTrue(config.ioHooks.enabled)
            XCTAssertEqual(config.ioHooks.hooks.count, 1)
            XCTAssertEqual(config.ioHooks.hooks[0].name, "test")
        }
    }

    func testPtermConfigDefaultHasIOHooksDisabled() {
        XCTAssertFalse(PtermConfig.default.ioHooks.enabled)
        XCTAssertTrue(PtermConfig.default.ioHooks.hooks.isEmpty)
    }
}

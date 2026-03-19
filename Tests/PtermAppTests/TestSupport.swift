import Foundation
import PtermCore
@testable import PtermApp
import XCTest

func projectRootURL(filePath: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(filePath)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func requiredReleaseAppExecutableURL(
    filePath: StaticString = #filePath,
    line: UInt = #line
) throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    let executableURL: URL
    if let override = environment["PTERM_TEST_RELEASE_APP_EXECUTABLE"], !override.isEmpty {
        executableURL = URL(fileURLWithPath: override)
    } else {
        executableURL = projectRootURL(filePath: filePath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("pterm.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("PtermApp", isDirectory: false)
    }

    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        XCTFail(
            "Release app executable is required for this regression test. Build and bundle the release app first at \(executableURL.path).",
            file: filePath,
            line: line
        )
        throw NSError(
            domain: "PtermAppTests.ReleaseApp",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Missing release app executable at \(executableURL.path)"]
        )
    }

    return executableURL
}

func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

func withTemporaryHomeDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    try withTemporaryDirectory { directory in
        let previousHome = getenv("HOME").map { String(cString: $0) }
        setenv("HOME", directory.path, 1)
        defer {
            if let previousHome {
                setenv("HOME", previousHome, 1)
            } else {
                unsetenv("HOME")
            }
        }
        return try body(directory)
    }
}

func withTemporaryPtermProfile<T>(_ body: (URL) throws -> T) throws -> T {
    try withTemporaryDirectory { directory in
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let profileRoot = directory.appendingPathComponent(
            ".pterm_\(timestamp)_\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        precondition(
            !FileManager.default.fileExists(atPath: profileRoot.path),
            "Temporary pterm profile root must start from a fresh path"
        )
        try FileManager.default.createDirectory(
            at: profileRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return try PtermDirectories.withBaseDirectory(profileRoot) {
            try body(profileRoot)
        }
    }
}

func withTemporaryPtermConfig<T>(_ body: (URL) throws -> T) throws -> T {
    try withTemporaryPtermProfile { profileRoot in
        let configURL = profileRoot.appendingPathComponent("config.json")
        precondition(
            !FileManager.default.fileExists(atPath: configURL.path),
            "Temporary pterm config must not reuse a pre-existing file"
        )
        try "{}".write(to: configURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return try body(configURL)
    }
}

func posixPermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return attributes[.posixPermissions] as? Int ?? 0
}

@MainActor
func drainMainQueue(testCase: XCTestCase, timeout: TimeInterval = 1.0) {
    let expectation = testCase.expectation(description: "main-queue-drain")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    testCase.wait(for: [expectation], timeout: timeout)
}

final class TerminalModelHarness {
    let model: TerminalModel
    private var parser = VtParser()

    init(rows: Int = 6, cols: Int = 12) {
        model = TerminalModel(rows: rows, cols: cols)
        vt_parser_init(&parser, { parserPtr, action, codepoint, userData in
            guard let userData, let parserPtr else { return }
            let harness = Unmanaged<TerminalModelHarness>.fromOpaque(userData).takeUnretainedValue()
            harness.model.handleAction(action, codepoint: codepoint, parser: parserPtr)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        vt_parser_destroy(&parser)
    }

    func feed(_ string: String) {
        feed(codepoints: string.unicodeScalars.map(\.value))
    }

    func feed(codepoints: [UInt32]) {
        guard !codepoints.isEmpty else { return }
        vt_parser_feed(&parser, codepoints, codepoints.count)
    }
}

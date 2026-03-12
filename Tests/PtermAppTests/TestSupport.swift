import Foundation
import PtermCore
@testable import PtermApp
import XCTest

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

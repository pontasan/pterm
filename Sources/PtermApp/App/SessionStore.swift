import AppKit
import Foundation

struct PersistedTerminalSettings: Codable, Equatable {
    var textEncoding: String?
    var fontName: String?
    var fontSize: Double?
}

struct PersistedTerminalState: Codable, Equatable {
    var id: UUID
    var workspaceName: String
    var titleOverride: String?
    var currentDirectory: String
    var settings: PersistedTerminalSettings?
}

struct PersistedWindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(frame: NSRect) {
        x = frame.origin.x
        y = frame.origin.y
        width = frame.size.width
        height = frame.size.height
    }

    var rect: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }
}

struct PersistedSessionState: Codable, Equatable {
    enum PresentedMode: String, Codable, Equatable {
        case integrated
        case focused
        case split
    }

    var windowFrame: PersistedWindowFrame
    var focusedTerminalID: UUID?
    var presentedMode: PresentedMode
    var splitTerminalIDs: [UUID]
    var workspaceNames: [String]
    var terminals: [PersistedTerminalState]

    init(windowFrame: PersistedWindowFrame,
         focusedTerminalID: UUID?,
         presentedMode: PresentedMode,
         splitTerminalIDs: [UUID],
         workspaceNames: [String],
         terminals: [PersistedTerminalState]) {
        self.windowFrame = windowFrame
        self.focusedTerminalID = focusedTerminalID
        self.presentedMode = presentedMode
        self.splitTerminalIDs = splitTerminalIDs
        self.workspaceNames = workspaceNames
        self.terminals = terminals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowFrame = try container.decode(PersistedWindowFrame.self, forKey: .windowFrame)
        focusedTerminalID = try container.decodeIfPresent(UUID.self, forKey: .focusedTerminalID)
        presentedMode = try container.decodeIfPresent(PresentedMode.self, forKey: .presentedMode) ?? .integrated
        splitTerminalIDs = try container.decodeIfPresent([UUID].self, forKey: .splitTerminalIDs) ?? []
        workspaceNames = try container.decodeIfPresent([String].self, forKey: .workspaceNames) ?? []
        terminals = try container.decode([PersistedTerminalState].self, forKey: .terminals)
    }
}

enum SessionRestoreDecision: Equatable {
    case none
    case restore(PersistedSessionState)
    case requireUserConfirmation(PersistedSessionState)
}

final class SessionStore {
    private let directory: URL
    private let sessionURL: URL
    private let crashMarkerURL: URL
    private let fileManager: FileManager

    init(directory: URL = PtermDirectories.sessions, fileManager: FileManager = .default) {
        self.directory = directory
        self.sessionURL = directory.appendingPathComponent("session.json")
        self.crashMarkerURL = directory.appendingPathComponent("crash.marker")
        self.fileManager = fileManager
    }

    func prepareRestoreDecision() throws -> SessionRestoreDecision {
        guard fileManager.fileExists(atPath: sessionURL.path) else {
            try createCrashMarker()
            return .none
        }

        let data = try Data(contentsOf: sessionURL)
        let session = try JSONDecoder().decode(PersistedSessionState.self, from: data)
        let uncleanExit = fileManager.fileExists(atPath: crashMarkerURL.path)
        try createCrashMarker()
        return uncleanExit ? .requireUserConfirmation(session) : .restore(session)
    }

    func save(_ state: PersistedSessionState) throws {
        let data = try JSONEncoder.sessionEncoder.encode(state)
        try AtomicFileWriter.write(data, to: sessionURL, permissions: 0o600)
    }

    func markCleanShutdown() throws {
        if fileManager.fileExists(atPath: crashMarkerURL.path) {
            try fileManager.removeItem(at: crashMarkerURL)
        }
    }

    func clearSession() throws {
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }

        let contents = try fileManager.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: nil,
                                                           options: [])
        for item in contents {
            try fileManager.removeItem(at: item)
        }
    }

    private func createCrashMarker() throws {
        let data = Data("restoring".utf8)
        try AtomicFileWriter.write(data, to: crashMarkerURL, permissions: 0o600)
    }
}

private extension JSONEncoder {
    static var sessionEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

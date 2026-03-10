import Foundation

struct ConfiguredWorkspaceTerminal: Equatable {
    let title: String?
    let initialDirectory: String?
    let textEncoding: TerminalTextEncoding?
    let fontName: String?
    let fontSize: Double?
}

struct ConfiguredTerminalSettings: Equatable {
    let textEncoding: TerminalTextEncoding?
    let fontName: String?
    let fontSize: Double?
}

struct ConfiguredWorkspace: Equatable {
    let name: String
    let settings: ConfiguredTerminalSettings
    let terminals: [ConfiguredWorkspaceTerminal]
}

struct PtermConfig {
    let term: String
    let textEncoding: TerminalTextEncoding
    let fontName: String?
    let fontSize: Double?
    let memoryMax: Int
    let memoryInitial: Int
    let sessionScrollBufferPersistence: Bool
    let audit: AuditConfiguration
    let security: SecurityConfiguration
    let notification: NotificationConfiguration
    let shortcuts: ShortcutConfiguration
    let workspaces: [ConfiguredWorkspace]

    static let `default` = PtermConfig(
        term: TerminfoResolver.resolveConfiguredTerm(nil),
        textEncoding: .utf8,
        fontName: nil,
        fontSize: nil,
        memoryMax: 64 * 1024 * 1024,
        memoryInitial: 64 * 1024 * 1024,
        sessionScrollBufferPersistence: false,
        audit: .disabled,
        security: .default,
        notification: .default,
        shortcuts: .default,
        workspaces: []
    )
}

struct SecurityConfiguration {
    let osc52ClipboardRead: Bool
    let pasteConfirmation: Bool
    let mouseReportRestrictAlternateScreen: Bool
    let allowWindowResizeSequence: Bool

    static let `default` = SecurityConfiguration(
        osc52ClipboardRead: false,
        pasteConfirmation: true,
        mouseReportRestrictAlternateScreen: true,
        allowWindowResizeSequence: false
    )
}

enum PtermConfigStore {
    private struct ConfigFile: Decodable {
        let term: String?
        let textEncoding: String?
        let memoryMax: Int?
        let memoryInitial: Int?
        let session: SessionSection?
        let audit: AuditSection?
        let security: SecuritySection?
        let notification: NotificationSection?
        let shortcuts: ShortcutSection?

        enum CodingKeys: String, CodingKey {
            case term
            case textEncoding = "text_encoding"
            case memoryMax = "memory_max"
            case memoryInitial = "memory_initial"
            case session
            case audit
            case security
            case notification
            case shortcuts
        }
    }

    private struct SessionSection: Decodable {
        let scrollBufferPersistence: Bool?

        enum CodingKeys: String, CodingKey {
            case scrollBufferPersistence = "scroll_buffer_persistence"
        }
    }

    private struct AuditSection: Decodable {
        let enabled: Bool?
        let retentionDays: Int?
        let encryption: Bool?

        enum CodingKeys: String, CodingKey {
            case enabled
            case retentionDays = "retention_days"
            case encryption
        }
    }

    private struct SecuritySection: Decodable {
        let osc52ClipboardRead: Bool?
        let pasteConfirmation: Bool?
        let mouseReportRestrictAlternateScreen: Bool?
        let allowWindowResizeSequence: Bool?

        enum CodingKeys: String, CodingKey {
            case osc52ClipboardRead = "osc52_clipboard_read"
            case pasteConfirmation = "paste_confirmation"
            case mouseReportRestrictAlternateScreen = "mouse_report_restrict_alternate_screen"
            case allowWindowResizeSequence = "allow_window_resize_sequence"
        }
    }

    private struct ShortcutSection: Decodable {
        let values: [String: String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            values = try container.decode([String: String].self)
        }
    }

    private struct NotificationSection: Decodable {
        let controlReturn: String?
        let customSound: String?

        enum CodingKeys: String, CodingKey {
            case controlReturn = "control_return"
            case customSound = "custom_sound"
        }
    }

    static func load() -> PtermConfig {
        let defaults = PtermConfig.default
        guard let data = try? Data(contentsOf: PtermDirectories.config),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return defaults
        }

        let configuredMax = max(1024 * 1024, intValue(root["memory_max"]) ?? defaults.memoryMax)
        let configuredInitial = min(
            configuredMax,
            max(1024 * 1024, intValue(root["memory_initial"]) ?? configuredMax)
        )
        let font = dictionaryValue(root["font"])
        let session = dictionaryValue(root["session"])
        let audit = dictionaryValue(root["audit"])
        let security = dictionaryValue(root["security"])
        let notification = dictionaryValue(root["notification"])
        let shortcuts = dictionaryValue(root["shortcuts"])
        let workspaces = workspaceList(root["workspaces"])

        return PtermConfig(
            term: TerminfoResolver.resolveConfiguredTerm(stringValue(root["term"])),
            textEncoding: stringValue(root["text_encoding"]).flatMap(TerminalTextEncoding.init(configuredValue:)) ?? defaults.textEncoding,
            fontName: stringValue(font?["name"]) ?? stringValue(root["font_name"]),
            fontSize: normalizedFontSize(doubleValue(font?["size"]) ?? doubleValue(root["font_size"])),
            memoryMax: configuredMax,
            memoryInitial: configuredInitial,
            sessionScrollBufferPersistence: boolValue(session?["scroll_buffer_persistence"]) ?? defaults.sessionScrollBufferPersistence,
            audit: AuditConfiguration(
                enabled: boolValue(audit?["enabled"]) ?? defaults.audit.enabled,
                retentionDays: intValue(audit?["retention_days"]) ?? defaults.audit.retentionDays,
                encryption: boolValue(audit?["encryption"]) ?? defaults.audit.encryption
            ),
            security: SecurityConfiguration(
                osc52ClipboardRead: boolValue(security?["osc52_clipboard_read"]) ?? defaults.security.osc52ClipboardRead,
                pasteConfirmation: boolValue(security?["paste_confirmation"]) ?? defaults.security.pasteConfirmation,
                mouseReportRestrictAlternateScreen: boolValue(security?["mouse_report_restrict_alternate_screen"]) ?? defaults.security.mouseReportRestrictAlternateScreen,
                allowWindowResizeSequence: boolValue(security?["allow_window_resize_sequence"]) ?? defaults.security.allowWindowResizeSequence
            ),
            notification: NotificationConfiguration(
                controlReturn: stringValue(notification?["control_return"]).flatMap(ControlReturnMode.init(rawValue:)) ?? defaults.notification.controlReturn,
                customSound: stringValue(notification?["custom_sound"])
            ),
            shortcuts: ShortcutParser.parseMap(shortcuts?.compactMapValues(stringValue)),
            workspaces: workspaces
        )
    }

    private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return value as? Double
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return value as? Bool
    }

    private static func normalizedFontSize(_ value: Double?) -> Double? {
        guard let value else { return nil }
        let clamped = min(Double(MetalRenderer.maxFontSize), max(Double(MetalRenderer.minFontSize), value))
        return clamped
    }

    private static func workspaceList(_ value: Any?) -> [ConfiguredWorkspace] {
        guard let items = value as? [[String: Any]] else { return [] }

        return items.compactMap { workspace in
            guard let rawName = stringValue(workspace["name"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawName.isEmpty else {
                return nil
            }

            let workspaceSettings = terminalSettings(from: dictionaryValue(workspace["settings"]))
            let terminals = ((workspace["terminals"] as? [[String: Any]]) ?? []).map { terminal in
                let settings = terminalSettings(from: dictionaryValue(terminal["settings"]))
                return ConfiguredWorkspaceTerminal(
                    title: stringValue(terminal["title"]),
                    initialDirectory: stringValue(terminal["initial_directory"]),
                    textEncoding: settings.textEncoding ?? workspaceSettings.textEncoding,
                    fontName: settings.fontName ?? workspaceSettings.fontName,
                    fontSize: settings.fontSize ?? workspaceSettings.fontSize
                )
            }

            return ConfiguredWorkspace(name: rawName, settings: workspaceSettings, terminals: terminals)
        }
    }

    private static func terminalSettings(from dictionary: [String: Any]?) -> ConfiguredTerminalSettings {
        let font = dictionaryValue(dictionary?["font"])
        return ConfiguredTerminalSettings(
            textEncoding: stringValue(dictionary?["text_encoding"]).flatMap(TerminalTextEncoding.init(configuredValue:)),
            fontName: stringValue(dictionary?["font_name"]) ?? stringValue(font?["name"]),
            fontSize: normalizedFontSize(
                doubleValue(dictionary?["font_size"]) ?? doubleValue(font?["size"])
            )
        )
    }
}

enum TerminfoResolver {
    private static let searchRoots = [
        URL(fileURLWithPath: "/usr/share/terminfo"),
        URL(fileURLWithPath: "/usr/share/lib/terminfo"),
        URL(fileURLWithPath: "/lib/terminfo"),
        URL(fileURLWithPath: "/etc/terminfo")
    ]

    static func resolveConfiguredTerm(_ configured: String?) -> String {
        if let configured,
           isValidTermName(configured),
           terminfoExists(named: configured) {
            return configured
        }

        for candidate in ["xterm-256color", "xterm", "vt100"] {
            if terminfoExists(named: candidate) {
                return candidate
            }
        }

        return "xterm-256color"
    }

    private static func isValidTermName(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func terminfoExists(named term: String) -> Bool {
        let fm = FileManager.default
        let first = String(term.prefix(1))
        let hex = String(format: "%02x", first.utf8.first ?? 0)

        for root in searchRoots {
            let direct = root.appendingPathComponent(first).appendingPathComponent(term)
            if fm.fileExists(atPath: direct.path) {
                return true
            }

            let hexPath = root.appendingPathComponent(hex).appendingPathComponent(term)
            if fm.fileExists(atPath: hexPath.path) {
                return true
            }
        }

        return false
    }
}

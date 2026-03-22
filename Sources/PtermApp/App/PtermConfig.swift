import Foundation

struct RGBColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    static let defaultTerminalForeground = RGBColor(red: 0xFF, green: 0xFF, blue: 0xFF)
    static let defaultTerminalBackground = RGBColor(red: 0x00, green: 0x00, blue: 0x00)

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard normalized.count == 6,
              let value = UInt32(normalized, radix: 16) else {
            return nil
        }
        self.red = UInt8((value >> 16) & 0xFF)
        self.green = UInt8((value >> 8) & 0xFF)
        self.blue = UInt8(value & 0xFF)
    }

    var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }
}

struct TerminalAppearanceConfiguration: Equatable {
    let foreground: RGBColor
    let background: RGBColor
    let backgroundOpacity: Double

    static let `default` = TerminalAppearanceConfiguration(
        foreground: .defaultTerminalForeground,
        background: .defaultTerminalBackground,
        backgroundOpacity: 0.0
    )

    var normalizedBackgroundOpacity: Double {
        min(1.0, max(0.0, backgroundOpacity))
    }
}

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

struct ShellLaunchConfiguration: Equatable {
    static let defaultLaunchOrder = [
        "/bin/zsh",
        "/bin/bash",
        "/bin/sh"
    ]

    let launchOrder: [String]

    static let `default` = ShellLaunchConfiguration(launchOrder: defaultLaunchOrder)

    init(launchOrder: [String]) {
        self.launchOrder = Self.normalizedLaunchOrder(launchOrder)
    }

    static func normalizedLaunchOrder(_ values: [String]) -> [String] {
        var normalized: [String] = []
        var seen = Set<String>()

        for rawValue in values {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.hasPrefix("/") else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            normalized.append(trimmed)
        }

        return normalized.isEmpty ? defaultLaunchOrder : normalized
    }
}

struct TextInteractionConfiguration: Equatable {
    let outputConfirmedInputAnimation: Bool
    let outputFrameThrottlingMode: OutputFrameThrottlingMode
    let showFPSInStatusBar: Bool
    let typewriterSoundEnabled: Bool

    static let `default` = TextInteractionConfiguration(
        outputConfirmedInputAnimation: true,
        outputFrameThrottlingMode: .continuous,
        showFPSInStatusBar: false,
        typewriterSoundEnabled: false
    )
}

enum OutputFrameThrottlingMode: String, Equatable {
    case aggressive
    case balanced
    case continuous

    init?(configuredValue: String) {
        self.init(rawValue: configuredValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    var configuredValue: String { rawValue }

    var redrawCadenceCoefficient: Double {
        switch self {
        case .aggressive:
            return 0.5
        case .balanced:
            return 1.0
        case .continuous:
            return 50.0
        }
    }

    var preferredOutputFPSCap: Int {
        switch self {
        case .aggressive:
            return 30
        case .balanced:
            return 60
        case .continuous:
            return 100
        }
    }
}

struct MCPServerConfiguration: Equatable {
    static let defaultPort = 46257
    static let minimumPort = 1024
    static let maximumPort = 65_535

    let enabled: Bool
    let port: Int

    static let `default` = MCPServerConfiguration(enabled: true, port: defaultPort)

    init(enabled: Bool, port: Int) {
        self.enabled = enabled
        self.port = Self.normalizedPort(port)
    }

    static func normalizedPort(_ value: Int?) -> Int {
        guard let value else { return defaultPort }
        return min(maximumPort, max(minimumPort, value))
    }
}

enum AIModelType: String, Equatable, CaseIterable {
    case claudeCode = "claude_code"
    case codex = "codex"
    case gemini = "gemini"

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    init?(configuredValue: String) {
        self.init(rawValue: configuredValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    var configuredValue: String { rawValue }
}

struct AIConfiguration: Equatable {
    let enabled: Bool
    let language: String
    let model: AIModelType
    let dangerouslySkipPermissions: Bool

    /// Resolve the user's actual system language, bypassing the app bundle's
    /// localization table which can override `Locale.current` in GUI apps.
    static var defaultLanguage: String {
        if let preferred = Locale.preferredLanguages.first {
            return Locale(identifier: preferred).identifier
        }
        return Locale.current.identifier
    }

    static let `default` = AIConfiguration(
        enabled: true,
        language: defaultLanguage,
        model: .claudeCode,
        dangerouslySkipPermissions: false
    )
}

struct PtermConfig {
    let term: String
    let textEncoding: TerminalTextEncoding
    let shellLaunch: ShellLaunchConfiguration
    let textInteraction: TextInteractionConfiguration
    let fontName: String?
    let fontSize: Double?
    let terminalAppearance: TerminalAppearanceConfiguration
    let memoryMax: Int
    let memoryInitial: Int
    let sessionScrollBufferPersistence: Bool
    let audit: AuditConfiguration
    let security: SecurityConfiguration
    let mcpServer: MCPServerConfiguration
    let ai: AIConfiguration
    let ioHooks: IOHookConfiguration
    let shortcuts: ShortcutConfiguration
    let workspaces: [ConfiguredWorkspace]

    static let `default` = PtermConfig(
        term: TerminfoResolver.resolveConfiguredTerm(nil),
        textEncoding: .utf8,
        shellLaunch: .default,
        textInteraction: .default,
        fontName: nil,
        fontSize: nil,
        terminalAppearance: .default,
        memoryMax: 64 * 1024 * 1024,
        memoryInitial: 4 * 1024 * 1024,
        sessionScrollBufferPersistence: false,
        audit: .disabled,
        security: .default,
        mcpServer: .default,
        ai: .default,
        ioHooks: .default,
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
        let shortcuts: ShortcutSection?

        enum CodingKeys: String, CodingKey {
            case term
            case textEncoding = "text_encoding"
            case memoryMax = "memory_max"
            case memoryInitial = "memory_initial"
            case session
            case audit
            case security
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

    static func load(from configURL: URL = PtermDirectories.config) -> PtermConfig {
        let defaults = PtermConfig.default
        guard let data = try? Data(contentsOf: configURL),
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
        let appearance = dictionaryValue(root["appearance"])
        let session = dictionaryValue(root["session"])
        let audit = dictionaryValue(root["audit"])
        let security = dictionaryValue(root["security"])
        let mcpServer = dictionaryValue(root["mcp_server"])
        let aiSection = dictionaryValue(root["ai"])
        let shortcuts = dictionaryValue(root["shortcuts"])
        let shells = dictionaryValue(root["shells"])
        let textInteraction = dictionaryValue(root["text_interaction"])
        let workspaces = workspaceList(root["workspaces"])

        return PtermConfig(
            term: TerminfoResolver.resolveConfiguredTerm(stringValue(root["term"])),
            textEncoding: stringValue(root["text_encoding"]).flatMap(TerminalTextEncoding.init(configuredValue:)) ?? defaults.textEncoding,
            shellLaunch: ShellLaunchConfiguration(
                launchOrder: stringArrayValue(shells?["launch_order"]) ?? defaults.shellLaunch.launchOrder
            ),
            textInteraction: TextInteractionConfiguration(
                outputConfirmedInputAnimation: boolValue(textInteraction?["output_confirmed_input_animation"]) ?? defaults.textInteraction.outputConfirmedInputAnimation,
                outputFrameThrottlingMode: {
                    if let string = stringValue(textInteraction?["output_frame_throttling_mode"]),
                       let mode = OutputFrameThrottlingMode(configuredValue: string) {
                        return mode
                    }
                    if let legacyEnabled = boolValue(textInteraction?["output_frame_throttling_enabled"]) {
                        return legacyEnabled ? .balanced : .continuous
                    }
                    return defaults.textInteraction.outputFrameThrottlingMode
                }(),
                showFPSInStatusBar: boolValue(textInteraction?["show_fps_in_status_bar"]) ?? defaults.textInteraction.showFPSInStatusBar,
                typewriterSoundEnabled: boolValue(textInteraction?["typewriter_sound_enabled"]) ?? defaults.textInteraction.typewriterSoundEnabled
            ),
            fontName: stringValue(font?["name"]) ?? stringValue(root["font_name"]),
            fontSize: normalizedFontSize(doubleValue(font?["size"]) ?? doubleValue(root["font_size"])),
            terminalAppearance: TerminalAppearanceConfiguration(
                foreground: stringValue(appearance?["terminal_foreground_color"]).flatMap(RGBColor.init(hexString:)) ?? defaults.terminalAppearance.foreground,
                background: stringValue(appearance?["terminal_background_color"]).flatMap(RGBColor.init(hexString:)) ?? defaults.terminalAppearance.background,
                backgroundOpacity: normalizedOpacity(doubleValue(appearance?["terminal_background_opacity"]) ?? defaults.terminalAppearance.backgroundOpacity)
            ),
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
            mcpServer: MCPServerConfiguration(
                enabled: boolValue(mcpServer?["enabled"]) ?? defaults.mcpServer.enabled,
                port: MCPServerConfiguration.normalizedPort(intValue(mcpServer?["port"]) ?? defaults.mcpServer.port)
            ),
            ai: AIConfiguration(
                enabled: boolValue(aiSection?["enabled"]) ?? defaults.ai.enabled,
                language: stringValue(aiSection?["language"]) ?? defaults.ai.language,
                model: stringValue(aiSection?["model"]).flatMap(AIModelType.init(configuredValue:)) ?? defaults.ai.model,
                dangerouslySkipPermissions: boolValue(aiSection?["dangerously_skip_permissions"]) ?? defaults.ai.dangerouslySkipPermissions
            ),
            ioHooks: IOHookConfiguration.parse(from: root),
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

    private static func stringArrayValue(_ value: Any?) -> [String]? {
        value as? [String]
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

    private static func normalizedOpacity(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
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

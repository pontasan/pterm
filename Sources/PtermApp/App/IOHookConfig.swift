import Foundation

/// Target stream for an I/O hook.
enum IOHookTarget: String, Equatable {
    /// Observe data written to the terminal (user keystrokes).
    case stdin
    /// Observe combined stdout+stderr output from the terminal.
    case output
}

/// Buffering mode for an I/O hook.
enum IOHookBufferingMode: String, Equatable {
    /// Raw PTY bytes, no transformation, immediate delivery.
    case immediate
    /// Clean text extracted from VT parser, delivered per line.
    case line
    /// Clean text, flushed when output goes silent for idle_ms.
    case idle
}

/// Configuration for a single I/O hook entry.
struct IOHookEntry: Equatable {
    let enabled: Bool
    let name: String
    let target: IOHookTarget
    let buffering: IOHookBufferingMode
    let idleMs: Int
    let bufferSize: Int
    let command: String
    let processMatch: String?
    let processMatchRegex: NSRegularExpression?
    let includeChildren: Bool

    static func == (lhs: IOHookEntry, rhs: IOHookEntry) -> Bool {
        lhs.enabled == rhs.enabled &&
        lhs.name == rhs.name &&
        lhs.target == rhs.target &&
        lhs.buffering == rhs.buffering &&
        lhs.idleMs == rhs.idleMs &&
        lhs.bufferSize == rhs.bufferSize &&
        lhs.command == rhs.command &&
        lhs.processMatch == rhs.processMatch &&
        lhs.includeChildren == rhs.includeChildren
    }

    static let defaultIdleMs = 500
    static let minIdleMs = 1
    static let maxIdleMs = 10000

    static let defaultBufferSize = 65536
    static let minBufferSize = 1024
    static let maxBufferSize = 16_777_216
}

/// Top-level I/O hooks configuration.
struct IOHookConfiguration: Equatable {
    /// Master switch.  When false, no hook infrastructure is instantiated.
    let enabled: Bool
    let hooks: [IOHookEntry]

    static let `default` = IOHookConfiguration(enabled: false, hooks: [])

    static func == (lhs: IOHookConfiguration, rhs: IOHookConfiguration) -> Bool {
        lhs.enabled == rhs.enabled && lhs.hooks == rhs.hooks
    }
}

// MARK: - Parsing

extension IOHookConfiguration {

    /// Parse I/O hooks configuration from the root config JSON dictionary.
    static func parse(from root: [String: Any]) -> IOHookConfiguration {
        let enabled = (root["io_hooks_enabled"] as? Bool) ?? IOHookConfiguration.default.enabled

        guard let hookArray = root["io_hooks"] as? [[String: Any]] else {
            return IOHookConfiguration(enabled: enabled, hooks: [])
        }

        let hooks: [IOHookEntry] = hookArray.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            guard let command = dict["command"] as? String, !command.isEmpty else { return nil }

            let targetString = (dict["target"] as? String) ?? ""
            guard let target = IOHookTarget(rawValue: targetString) else { return nil }

            let bufferingString = (dict["buffering"] as? String) ?? IOHookBufferingMode.line.rawValue
            let buffering = IOHookBufferingMode(rawValue: bufferingString) ?? .line

            let rawIdleMs = (dict["idle_ms"] as? Int) ?? IOHookEntry.defaultIdleMs
            let idleMs = max(IOHookEntry.minIdleMs, min(IOHookEntry.maxIdleMs, rawIdleMs))

            let rawBufferSize = (dict["buffer_size"] as? Int) ?? IOHookEntry.defaultBufferSize
            let bufferSize = max(IOHookEntry.minBufferSize, min(IOHookEntry.maxBufferSize, rawBufferSize))

            let processMatchString = dict["process_match"] as? String
            var processMatchRegex: NSRegularExpression?
            if let pattern = processMatchString, !pattern.isEmpty {
                do {
                    processMatchRegex = try NSRegularExpression(pattern: pattern, options: [])
                } catch {
                    NSLog("[pterm] I/O hook '%@': invalid process_match regex '%@' — hook disabled: %@",
                          name, pattern, error.localizedDescription)
                    return nil
                }
            }

            let hookEnabled = (dict["enabled"] as? Bool) ?? true
            let includeChildren = (dict["include_children"] as? Bool) ?? false

            return IOHookEntry(
                enabled: hookEnabled,
                name: name,
                target: target,
                buffering: buffering,
                idleMs: idleMs,
                bufferSize: bufferSize,
                command: command,
                processMatch: processMatchString,
                processMatchRegex: processMatchRegex,
                includeChildren: includeChildren
            )
        }

        return IOHookConfiguration(enabled: enabled, hooks: hooks)
    }
}

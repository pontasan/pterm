import Foundation

enum LaunchOptionsError: Error, LocalizedError, Equatable {
    case missingValue(String)
    case duplicateProfileRootOption
    case emptyProfileRootPath
    case invalidRestoreSessionMode(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            return "Missing value for launch option \(option)."
        case .duplicateProfileRootOption:
            return "Profile root was specified more than once."
        case .emptyProfileRootPath:
            return "Profile root path must not be empty."
        case .invalidRestoreSessionMode(let value):
            return "Invalid value for --restore-session: \(value). Expected one of: attempt, force, never."
        }
    }
}

enum RestoreSessionMode: String, Equatable {
    case attempt
    case force
    case never
}

enum LaunchImmediateAction: Equatable {
    case help
    case version
}

struct LaunchOptions: Equatable {
    let profileRoot: URL?
    let restoreSessionMode: RestoreSessionMode
    let immediateAction: LaunchImmediateAction?

    static func parse(arguments: [String],
                      currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                                                  isDirectory: true)) throws -> LaunchOptions {
        var index = 0
        var profileRoot: URL?
        var restoreSessionMode: RestoreSessionMode = .attempt
        var immediateAction: LaunchImmediateAction?

        while index < arguments.count {
            let argument = arguments[index]
            if let value = profileRootValue(for: argument, nextArgument: arguments[safe: index + 1]) {
                if profileRoot != nil {
                    throw LaunchOptionsError.duplicateProfileRootOption
                }
                if requiresSeparateValue(argument), arguments[safe: index + 1] == nil {
                    throw LaunchOptionsError.missingValue(argument)
                }
                if requiresSeparateValue(argument) {
                    index += 1
                }
                profileRoot = try resolveProfileRoot(value, currentDirectory: currentDirectory)
            } else if let value = restoreSessionModeValue(for: argument, nextArgument: arguments[safe: index + 1]) {
                if requiresSeparateValue(argument) && arguments[safe: index + 1] == nil {
                    throw LaunchOptionsError.missingValue(argument)
                }
                if requiresSeparateValue(argument) {
                    index += 1
                }
                guard let parsedMode = RestoreSessionMode(rawValue: value) else {
                    throw LaunchOptionsError.invalidRestoreSessionMode(value)
                }
                restoreSessionMode = parsedMode
            } else if argument == "--help" || argument == "-h" {
                immediateAction = .help
            } else if argument == "--version" || argument == "-v" {
                immediateAction = .version
            } else if argument == "--user-data-dir" {
                throw LaunchOptionsError.missingValue(argument)
            }
            index += 1
        }

        return LaunchOptions(
            profileRoot: profileRoot,
            restoreSessionMode: restoreSessionMode,
            immediateAction: immediateAction
        )
    }

    private static func profileRootValue(for argument: String, nextArgument: String?) -> String? {
        if argument == "--user-data-dir" {
            return nextArgument
        }
        if argument.hasPrefix("--user-data-dir=") {
            return String(argument.dropFirst("--user-data-dir=".count))
        }
        return nil
    }

    private static func restoreSessionModeValue(for argument: String, nextArgument: String?) -> String? {
        if argument == "--restore-session" {
            return nextArgument
        }
        if argument.hasPrefix("--restore-session=") {
            return String(argument.dropFirst("--restore-session=".count))
        }
        return nil
    }

    private static func requiresSeparateValue(_ argument: String) -> Bool {
        argument == "--user-data-dir" || argument == "--restore-session"
    }

    private static func resolveProfileRoot(_ rawValue: String,
                                           currentDirectory: URL) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LaunchOptionsError.emptyProfileRootPath
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        let resolved: URL
        if expanded.hasPrefix("/") {
            resolved = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            resolved = currentDirectory.appendingPathComponent(expanded, isDirectory: true)
        }
        return resolved.standardizedFileURL
    }
}

enum PtermCommandLine {
    static func versionText(bundle: Bundle = .main) -> String {
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "pterm"
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildVersion) {
        case let (short?, build?) where short != build:
            return "\(name) \(short) (\(build))"
        case let (short?, _):
            return "\(name) \(short)"
        case let (_, build?):
            return "\(name) \(build)"
        default:
            return "\(name) development"
        }
    }

    static func helpText(bundle: Bundle = .main) -> String {
        let executable = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "pterm"

        return """
        Usage: \(executable) [options]

        Options:
          --help, -h
              Show this help and exit.

          --version, -v
              Show version information and exit.

          --user-data-dir <path>
          --user-data-dir=<path>
              Use a custom profile directory.

          --restore-session <mode>
          --restore-session=<mode>
              Control session restore behavior.
              Modes:
                attempt  Try restoring. If the previous exit was unclean, ask for confirmation.
                force    Restore without confirmation, even after an unclean exit.
                never    Do not restore any previous session.
        """
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

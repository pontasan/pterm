import Foundation

enum LaunchOptionsError: Error, LocalizedError, Equatable {
    case missingValue(String)
    case duplicateProfileRootOption
    case emptyProfileRootPath
    case invalidRestoreSessionMode(String)
    case duplicateUnattendedOption
    case conflictingUnattendedRestoreSessionMode
    case duplicateCLIModeOption
    case duplicateCommandOption
    case emptyCommandPath

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
        case .duplicateUnattendedOption:
            return "The --unattended option was specified more than once."
        case .conflictingUnattendedRestoreSessionMode:
            return "--unattended cannot be combined with --restore-session=never."
        case .duplicateCLIModeOption:
            return "CLI mode was specified more than once."
        case .duplicateCommandOption:
            return "Command was specified more than once."
        case .emptyCommandPath:
            return "Command path must not be empty."
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

struct DirectLaunchOptions: Equatable {
    let executablePath: String
    let arguments: [String]
}

struct LaunchOptions: Equatable {
    let profileRoot: URL?
    let restoreSessionMode: RestoreSessionMode
    let unattended: Bool
    let cliMode: Bool
    let immediateAction: LaunchImmediateAction?
    let directLaunch: DirectLaunchOptions?

    static func parse(arguments: [String],
                      currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                                                  isDirectory: true)) throws -> LaunchOptions {
        var index = 0
        var profileRoot: URL?
        var restoreSessionMode: RestoreSessionMode = .attempt
        var explicitRestoreSessionMode: RestoreSessionMode?
        var unattended = false
        var cliMode = false
        var immediateAction: LaunchImmediateAction?
        var directLaunch: DirectLaunchOptions?

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
                explicitRestoreSessionMode = parsedMode
            } else if argument == "--unattended" {
                if unattended {
                    throw LaunchOptionsError.duplicateUnattendedOption
                }
                unattended = true
            } else if let value = commandValue(for: argument, nextArgument: arguments[safe: index + 1]) {
                if directLaunch != nil {
                    throw LaunchOptionsError.duplicateCommandOption
                }
                if requiresSeparateValue(argument), arguments[safe: index + 1] == nil {
                    throw LaunchOptionsError.missingValue(argument)
                }
                if requiresSeparateValue(argument) {
                    index += 1
                }
                let executablePath = try resolveCommandPath(value)
                var directLaunchArguments: [String] = []
                if arguments[safe: index + 1] == "--" {
                    directLaunchArguments = Array(arguments.dropFirst(index + 2))
                    index = arguments.count
                }
                directLaunch = DirectLaunchOptions(
                    executablePath: executablePath,
                    arguments: directLaunchArguments
                )
            } else if argument == "--cli" {
                if cliMode {
                    throw LaunchOptionsError.duplicateCLIModeOption
                }
                cliMode = true
            } else if argument == "--help" || argument == "-h" {
                immediateAction = .help
            } else if argument == "--version" || argument == "-v" {
                immediateAction = .version
            } else if argument == "--user-data-dir" {
                throw LaunchOptionsError.missingValue(argument)
            } else if argument == "--command" {
                throw LaunchOptionsError.missingValue(argument)
            } else if argument == "--" {
                if cliMode {
                    let remainingArguments = Array(arguments.dropFirst(index + 1))
                    if let command = remainingArguments.first {
                        if directLaunch != nil {
                            throw LaunchOptionsError.duplicateCommandOption
                        }
                        directLaunch = DirectLaunchOptions(
                            executablePath: try resolveCommandPath(command),
                            arguments: Array(remainingArguments.dropFirst())
                        )
                    }
                }
                break
            }
            index += 1
        }

        if unattended {
            if explicitRestoreSessionMode == .never {
                throw LaunchOptionsError.conflictingUnattendedRestoreSessionMode
            }
            restoreSessionMode = .force
        }

        return LaunchOptions(
            profileRoot: profileRoot,
            restoreSessionMode: restoreSessionMode,
            unattended: unattended,
            cliMode: cliMode,
            immediateAction: immediateAction,
            directLaunch: directLaunch
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

    private static func commandValue(for argument: String, nextArgument: String?) -> String? {
        if argument == "--command" {
            return nextArgument
        }
        if argument.hasPrefix("--command=") {
            return String(argument.dropFirst("--command=".count))
        }
        return nil
    }

    private static func requiresSeparateValue(_ argument: String) -> Bool {
        argument == "--user-data-dir" || argument == "--restore-session" || argument == "--command"
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

    private static func resolveCommandPath(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LaunchOptionsError.emptyCommandPath
        }
        return NSString(string: trimmed).expandingTildeInPath
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
        Usage:
          \(executable) [options]
          \(executable) --cli [options]
          \(executable) --cli -- <command> [arguments...]

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

          --unattended
              Start in unattended verification mode.
              This implies --restore-session=force and suppresses quit confirmation
              dialogs when terminals are still running.

          --cli
              Run without opening the GUI window.
              Start a single terminal session and bridge the parent process stdin/stdout/stderr
              to that session. Without a command, pterm launches the configured login shell
              in the current working directory.
              Examples:
                \(executable) --cli
                \(executable) --cli -- /bin/zsh
                \(executable) --cli -- tail -F /var/log/system.log

          --command <path>
          --command=<path>
              Launch the given executable directly in a transient focused terminal.
              To pass arguments to the launched program, place `--` after the command
              option and put all remaining values after it.
              Example:
                \(executable) --command /opt/homebrew/bin/vttest
                \(executable) --command /usr/bin/env -- printenv TERM
        """
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

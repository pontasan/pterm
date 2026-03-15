import Foundation

enum LaunchOptionsError: Error, LocalizedError, Equatable {
    case missingValue(String)
    case duplicateProfileRootOption
    case emptyProfileRootPath

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            return "Missing value for launch option \(option)."
        case .duplicateProfileRootOption:
            return "Profile root was specified more than once."
        case .emptyProfileRootPath:
            return "Profile root path must not be empty."
        }
    }
}

struct LaunchOptions: Equatable {
    let profileRoot: URL?

    static func parse(arguments: [String],
                      currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                                                  isDirectory: true)) throws -> LaunchOptions {
        var index = 0
        var profileRoot: URL?

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
            } else if argument == "--user-data-dir" {
                throw LaunchOptionsError.missingValue(argument)
            }
            index += 1
        }

        return LaunchOptions(profileRoot: profileRoot)
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

    private static func requiresSeparateValue(_ argument: String) -> Bool {
        argument == "--user-data-dir"
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

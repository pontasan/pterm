import AppKit
import Darwin

// pterm - macOS Terminal Emulator
//
// Entry point. Bootstraps NSApplication with our AppDelegate.

// Ignore SIGPIPE globally so that write() to a broken pipe (e.g. a crashed
// I/O hook process) returns EPIPE instead of killing the application.
signal(SIGPIPE, SIG_IGN)

let launchOptions: LaunchOptions

do {
    launchOptions = try LaunchOptions.parse(arguments: Array(CommandLine.arguments.dropFirst()))
    if let profileRoot = launchOptions.profileRoot {
        PtermDirectories.setBaseDirectory(profileRoot)
    }
} catch {
    fatalError("Failed to parse launch arguments: \(error)")
}

if let immediateAction = launchOptions.immediateAction {
    switch immediateAction {
    case .help:
        FileHandle.standardOutput.write(Data((PtermCommandLine.helpText() + "\n").utf8))
    case .version:
        FileHandle.standardOutput.write(Data((PtermCommandLine.versionText() + "\n").utf8))
    }
    exit(EXIT_SUCCESS)
}

if launchOptions.cliMode {
    PtermDirectories.ensureDirectories()
    let config = PtermConfigStore.load()
    let session = CLILaunchSession(launchOptions: launchOptions, config: config)
    do {
        try session.run()
        fatalError("CLI session returned unexpectedly.")
    } catch {
        FileHandle.standardError.write(Data("Failed to start CLI session: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

let app = NSApplication.shared
if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
   let icon = NSImage(contentsOf: iconURL) {
    app.applicationIconImage = icon
}
let delegate = AppDelegate(launchOptions: launchOptions)
app.delegate = delegate
app.run()

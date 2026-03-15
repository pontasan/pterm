import AppKit

// pterm - macOS Terminal Emulator
//
// Entry point. Bootstraps NSApplication with our AppDelegate.

do {
    let launchOptions = try LaunchOptions.parse(arguments: Array(CommandLine.arguments.dropFirst()))
    if let profileRoot = launchOptions.profileRoot {
        PtermDirectories.setBaseDirectory(profileRoot)
    }
} catch {
    fatalError("Failed to parse launch arguments: \(error)")
}

let app = NSApplication.shared
if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
   let icon = NSImage(contentsOf: iconURL) {
    app.applicationIconImage = icon
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()

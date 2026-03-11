import AppKit

// pterm - macOS Terminal Emulator
//
// Entry point. Bootstraps NSApplication with our AppDelegate.

let app = NSApplication.shared
if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
   let icon = NSImage(contentsOf: iconURL) {
    app.applicationIconImage = icon
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()

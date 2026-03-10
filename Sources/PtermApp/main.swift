import AppKit

// pterm - macOS Terminal Emulator
//
// Entry point. Bootstraps NSApplication with our AppDelegate.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

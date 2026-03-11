import AppKit

extension NSAlert {
    /// Creates an NSAlert with the application icon pre-configured.
    static func pterm() -> NSAlert {
        let alert = NSAlert()
        if let icon = NSApp.applicationIconImage {
            alert.icon = icon
        }
        return alert
    }
}

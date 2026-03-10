import AppKit

/// Converts NSEvent keyboard events to terminal input byte sequences.
///
/// Handles:
/// - ASCII printable characters
/// - Control key combinations (Ctrl+C -> 0x03, etc.)
/// - Arrow keys, Home, End, PgUp, PgDn
/// - Function keys
/// - Application cursor mode (DECCKM)
final class KeyboardHandler {
    private weak var controller: TerminalController?

    init(controller: TerminalController) {
        self.controller = controller
    }

    func handleKeyDown(event: NSEvent) {
        guard let controller = controller else { return }

        let modifiers = event.modifierFlags

        // Control key combinations
        if modifiers.contains(.control) {
            if let chars = event.charactersIgnoringModifiers,
               let scalar = chars.unicodeScalars.first {
                let code = scalar.value
                // Ctrl+A (0x01) through Ctrl+Z (0x1A)
                if code >= 0x61 && code <= 0x7A { // a-z
                    let ctrlCode = UInt8(code - 0x60)
                    controller.sendInput(Data([ctrlCode]))
                    return
                }
                // Ctrl+[ = ESC (0x1B)
                if code == 0x5B {
                    controller.sendInput(Data([0x1B]))
                    return
                }
                // Ctrl+] = 0x1D
                if code == 0x5D {
                    controller.sendInput(Data([0x1D]))
                    return
                }
                // Ctrl+\ = 0x1C
                if code == 0x5C {
                    controller.sendInput(Data([0x1C]))
                    return
                }
            }
        }

        // Special keys
        if let specialInput = handleSpecialKey(event: event) {
            controller.sendInput(specialInput)
            return
        }

        // Regular text input
        if let characters = event.characters,
           let data = characters.data(using: .utf8) {
            controller.sendInput(data)
        }
    }

    private func handleSpecialKey(event: NSEvent) -> Data? {
        guard let controller = controller else { return nil }

        let appCursor = controller.withModel { $0.applicationCursorKeys }
        let prefix: String = appCursor ? "\u{1B}O" : "\u{1B}["

        switch event.keyCode {
        case 126: // Up
            return "\(prefix)A".data(using: .utf8)
        case 125: // Down
            return "\(prefix)B".data(using: .utf8)
        case 124: // Right
            return "\(prefix)C".data(using: .utf8)
        case 123: // Left
            return "\(prefix)D".data(using: .utf8)
        case 115: // Home
            return "\u{1B}[H".data(using: .utf8)
        case 119: // End
            return "\u{1B}[F".data(using: .utf8)
        case 116: // PageUp
            return "\u{1B}[5~".data(using: .utf8)
        case 121: // PageDown
            return "\u{1B}[6~".data(using: .utf8)
        case 117: // Delete (forward)
            return "\u{1B}[3~".data(using: .utf8)
        case 51: // Backspace
            return Data([0x7F])
        case 53: // Escape
            return Data([0x1B])
        case 76: // Enter (numpad)
            return Data([0x0D])
        case 36: // Return
            return Data([0x0D])
        case 48: // Tab
            if event.modifierFlags.contains(.shift) {
                return "\u{1B}[Z".data(using: .utf8) // Backtab
            }
            return Data([0x09])
        // Function keys
        case 122: return "\u{1B}OP".data(using: .utf8)  // F1
        case 120: return "\u{1B}OQ".data(using: .utf8)  // F2
        case 99:  return "\u{1B}OR".data(using: .utf8)  // F3
        case 118: return "\u{1B}OS".data(using: .utf8)  // F4
        case 96:  return "\u{1B}[15~".data(using: .utf8) // F5
        case 97:  return "\u{1B}[17~".data(using: .utf8) // F6
        case 98:  return "\u{1B}[18~".data(using: .utf8) // F7
        case 100: return "\u{1B}[19~".data(using: .utf8) // F8
        case 101: return "\u{1B}[20~".data(using: .utf8) // F9
        case 109: return "\u{1B}[21~".data(using: .utf8) // F10
        case 103: return "\u{1B}[23~".data(using: .utf8) // F11
        case 111: return "\u{1B}[24~".data(using: .utf8) // F12
        default:
            return nil
        }
    }
}

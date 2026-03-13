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
                    controller.sendInput(String(UnicodeScalar(code - 0x60)!))
                    return
                }
                // Ctrl+[ = ESC (0x1B)
                if code == 0x5B {
                    controller.sendInput("\u{1B}")
                    return
                }
                // Ctrl+] = 0x1D
                if code == 0x5D {
                    controller.sendInput(String(UnicodeScalar(0x1D)!))
                    return
                }
                // Ctrl+\ = 0x1C
                if code == 0x5C {
                    controller.sendInput(String(UnicodeScalar(0x1C)!))
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
        if let characters = event.characters {
            controller.sendInput(characters)
        }
    }

    func debugWillTreatAsRegularTextInput(event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
        if modifiers.contains(.control) {
            return false
        }
        if handleSpecialKey(event: event) != nil {
            return false
        }
        return event.characters != nil
    }

    func debugSpecialKeySelector(for event: NSEvent) -> Selector? {
        switch event.keyCode {
        case 51:
            return #selector(NSResponder.deleteBackward(_:))
        case 117:
            return #selector(NSResponder.deleteForward(_:))
        default:
            return nil
        }
    }

    @discardableResult
    func handleCommand(selector: Selector) -> Bool {
        guard let controller = controller else { return false }

        let appCursor = controller.withModel { $0.applicationCursorKeys }
        let prefix: String = appCursor ? "\u{1B}O" : "\u{1B}["

        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            controller.sendInput("\(prefix)A")
        case #selector(NSResponder.moveDown(_:)):
            controller.sendInput("\(prefix)B")
        case #selector(NSResponder.moveRight(_:)):
            controller.sendInput("\(prefix)C")
        case #selector(NSResponder.moveLeft(_:)):
            controller.sendInput("\(prefix)D")
        case #selector(NSResponder.moveToBeginningOfLine(_:)):
            controller.sendInput("\u{1B}[H")
        case #selector(NSResponder.moveToEndOfLine(_:)):
            controller.sendInput("\u{1B}[F")
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            controller.sendInput("\u{1B}[5~")
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            controller.sendInput("\u{1B}[6~")
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            controller.sendInput("\r")
        case #selector(NSResponder.insertTab(_:)):
            controller.sendInput("\t")
        case #selector(NSResponder.insertBacktab(_:)):
            controller.sendInput("\u{1B}[Z")
        case #selector(NSResponder.deleteBackward(_:)):
            controller.sendInput(String(UnicodeScalar(0x7F)!))
        case #selector(NSResponder.deleteForward(_:)):
            controller.sendInput("\u{1B}[3~")
        case #selector(NSResponder.cancelOperation(_:)):
            controller.sendInput("\u{1B}")
        default:
            return false
        }

        return true
    }

    private func handleSpecialKey(event: NSEvent) -> String? {
        guard let controller = controller else { return nil }

        let appCursor = controller.withModel { $0.applicationCursorKeys }
        let prefix: String = appCursor ? "\u{1B}O" : "\u{1B}["

        switch event.keyCode {
        case 126: // Up
            return "\(prefix)A"
        case 125: // Down
            return "\(prefix)B"
        case 124: // Right
            return "\(prefix)C"
        case 123: // Left
            return "\(prefix)D"
        case 115: // Home
            return "\u{1B}[H"
        case 119: // End
            return "\u{1B}[F"
        case 116: // PageUp
            return "\u{1B}[5~"
        case 121: // PageDown
            return "\u{1B}[6~"
        case 117: // Delete (forward)
            return "\u{1B}[3~"
        case 51: // Backspace
            return String(UnicodeScalar(0x7F)!)
        case 53: // Escape
            return "\u{1B}"
        case 76: // Enter (numpad)
            return "\r"
        case 36: // Return
            return "\r"
        case 48: // Tab
            if event.modifierFlags.contains(.shift) {
                return "\u{1B}[Z" // Backtab
            }
            return "\t"
        // Function keys
        case 122: return "\u{1B}OP"  // F1
        case 120: return "\u{1B}OQ"  // F2
        case 99:  return "\u{1B}OR"  // F3
        case 118: return "\u{1B}OS"  // F4
        case 96:  return "\u{1B}[15~" // F5
        case 97:  return "\u{1B}[17~" // F6
        case 98:  return "\u{1B}[18~" // F7
        case 100: return "\u{1B}[19~" // F8
        case 101: return "\u{1B}[20~" // F9
        case 109: return "\u{1B}[21~" // F10
        case 103: return "\u{1B}[23~" // F11
        case 111: return "\u{1B}[24~" // F12
        default:
            return nil
        }
    }
}

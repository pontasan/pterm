import AppKit
import Carbon.HIToolbox

/// Converts NSEvent keyboard events to terminal input byte sequences.
///
/// Handles:
/// - ASCII printable characters
/// - Control key combinations (Ctrl+C -> 0x03, etc.)
/// - Arrow keys, Home, End, PgUp, PgDn
/// - Function keys
/// - Application cursor mode (DECCKM)
final class KeyboardHandler {
    enum MCPKeyAction: Equatable {
        case input(String)
        case interrupt(UInt8)
    }

    private weak var controller: TerminalController?
    private let inputFeedbackPlayer: TypewriterKeyClicking
    private let inputFeedbackEnabled: () -> Bool

    init(controller: TerminalController,
         inputFeedbackPlayer: TypewriterKeyClicking = TypewriterKeyClickPlayerFactory.defaultPlayer,
         inputFeedbackEnabled: @escaping () -> Bool = { true }) {
        self.controller = controller
        self.inputFeedbackPlayer = inputFeedbackPlayer
        self.inputFeedbackEnabled = inputFeedbackEnabled
    }

    @discardableResult
    func handleKeyDown(event: NSEvent) -> Bool {
        guard let controller = controller else { return false }

        let modifiers = event.modifierFlags
        let keyboardModes = controller.withModel {
            (
                kittyKeyboardProtocolEnabled: $0.kittyKeyboardProtocolEnabled,
                modifyOtherKeysMode: $0.modifyOtherKeysMode,
                formatOtherKeysMode: $0.formatOtherKeysMode,
                modifyOtherKeysMask: $0.modifyOtherKeysMask
            )
        }

        if keyboardModes.kittyKeyboardProtocolEnabled,
           let kittySequence = kittyKeyboardInputSequence(for: event) {
            controller.sendInput(kittySequence)
            playInputFeedbackIfEnabled()
            return true
        }

        if let modifyOtherKeysSequence = modifyOtherKeysInputSequence(
            for: event,
            mode: keyboardModes.modifyOtherKeysMode,
            format: keyboardModes.formatOtherKeysMode,
            factoredModifierMask: keyboardModes.modifyOtherKeysMask
        ) {
            controller.sendInput(modifyOtherKeysSequence)
            playInputFeedbackIfEnabled()
            return true
        }

        // Control key combinations
        if modifiers.contains(.control) {
            if let chars = event.charactersIgnoringModifiers,
               let scalar = chars.unicodeScalars.first {
                let code = scalar.value
                if code == 0x63 { // c
                    controller.sendInput(String(UnicodeScalar(0x03)!))
                    playInputFeedbackIfEnabled()
                    return true
                }
                if code == 0x5A || code == 0x7A { // z
                    controller.sendInput(String(UnicodeScalar(0x1A)!))
                    playInputFeedbackIfEnabled()
                    return true
                }
                // Ctrl+A (0x01) through Ctrl+Z (0x1A)
                if code >= 0x61 && code <= 0x7A { // a-z
                    controller.sendInput(String(UnicodeScalar(code - 0x60)!))
                    playInputFeedbackIfEnabled()
                    return true
                }
                // Ctrl+[ = ESC (0x1B)
                if code == 0x5B {
                    controller.sendInput("\u{1B}")
                    playInputFeedbackIfEnabled()
                    return true
                }
                // Ctrl+] = 0x1D
                if code == 0x5D {
                    controller.sendInput(String(UnicodeScalar(0x1D)!))
                    playInputFeedbackIfEnabled()
                    return true
                }
                // Ctrl+\ = 0x1C
                if code == 0x5C {
                    controller.sendInput(String(UnicodeScalar(0x1C)!))
                    playInputFeedbackIfEnabled()
                    return true
                }
            }
        }

        // Special keys
        if let specialInput = debugInputSequence(for: event) {
            controller.sendInput(specialInput)
            playInputFeedbackIfEnabled()
            return true
        }

        if modifiers.contains(.option),
           !modifiers.contains(.command),
           !modifiers.contains(.control),
           let characters = event.characters,
           !characters.isEmpty {
            controller.sendInput("\u{1B}" + characters)
            playInputFeedbackIfEnabled()
            return true
        }

        // Regular text input
        if let characters = event.characters {
            controller.sendInput(characters)
            playInputFeedbackIfEnabled()
            return true
        }

        return false
    }

    func debugWillTreatAsRegularTextInput(event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
        if modifiers.contains(.control) {
            return false
        }
        if debugInputSequence(for: event) != nil {
            return false
        }
        return event.characters != nil
    }

    func debugInputSequence(for event: NSEvent) -> String? {
        guard let controller = controller else { return nil }
        let modes = controller.withModel { model in
            (
                appCursor: model.applicationCursorKeys,
                appKeypad: model.applicationKeypadMode,
                kittyKeyboard: model.kittyKeyboardProtocolEnabled,
                modifyOtherKeysMode: model.modifyOtherKeysMode,
                formatOtherKeysMode: model.formatOtherKeysMode,
                modifyOtherKeysMask: model.modifyOtherKeysMask
            )
        }
        if modes.kittyKeyboard,
           let kittySequence = kittyKeyboardInputSequence(for: event) {
            return kittySequence
        }
        if let modifyOtherKeysSequence = modifyOtherKeysInputSequence(
            for: event,
            mode: modes.modifyOtherKeysMode,
            format: modes.formatOtherKeysMode,
            factoredModifierMask: modes.modifyOtherKeysMask
        ) {
            return modifyOtherKeysSequence
        }
        return translatedSpecialKeyInput(
            for: event,
            applicationCursorKeys: modes.appCursor,
            applicationKeypadMode: modes.appKeypad
        )
    }

    func debugResolvedInput(for event: NSEvent) -> String? {
        if let special = debugInputSequence(for: event) {
            return special
        }
        let modifiers = event.modifierFlags
        if modifiers.contains(.option),
           !modifiers.contains(.command),
           !modifiers.contains(.control),
           let characters = event.characters,
           !characters.isEmpty {
            return "\u{1B}" + characters
        }
        return event.characters
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
            controller.sendInput(controller.newlineKeyInput())
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

        playInputFeedbackIfEnabled()
        return true
    }

    private func playInputFeedbackIfEnabled() {
        guard inputFeedbackEnabled() else { return }
        DispatchQueue.main.async { [inputFeedbackPlayer, inputFeedbackEnabled] in
            guard inputFeedbackEnabled() else { return }
            inputFeedbackPlayer.playKeystroke()
        }
    }

    static func mcpKeyAction(
        named rawKey: String,
        controller: TerminalController
    ) -> MCPKeyAction? {
        let key = rawKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        guard !key.isEmpty else { return nil }

        switch key {
        case "enter", "return":
            return .input(controller.newlineKeyInput())
        case "escape", "esc":
            return .input("\u{1B}")
        case "tab":
            return .input("\t")
        case "backtab", "shift_tab":
            return .input("\u{1B}[Z")
        case "backspace":
            return .input(String(UnicodeScalar(0x7F)!))
        case "insert":
            return .input("\u{1B}[2~")
        case "delete":
            return .input("\u{1B}[3~")
        case "up":
            return .input(namedArrowSequence(letter: "A", controller: controller))
        case "down":
            return .input(namedArrowSequence(letter: "B", controller: controller))
        case "right":
            return .input(namedArrowSequence(letter: "C", controller: controller))
        case "left":
            return .input(namedArrowSequence(letter: "D", controller: controller))
        case "home":
            let appCursor = controller.withModel { $0.applicationCursorKeys }
            return .input(appCursor ? "\u{1B}OH" : "\u{1B}[H")
        case "end":
            let appCursor = controller.withModel { $0.applicationCursorKeys }
            return .input(appCursor ? "\u{1B}OF" : "\u{1B}[F")
        case "page_up", "pageup":
            return .input("\u{1B}[5~")
        case "page_down", "pagedown":
            return .input("\u{1B}[6~")
        case "f1": return .input("\u{1B}[11~")
        case "f2": return .input("\u{1B}[12~")
        case "f3": return .input("\u{1B}[13~")
        case "f4": return .input("\u{1B}[14~")
        case "f5": return .input("\u{1B}[15~")
        case "f6": return .input("\u{1B}[17~")
        case "f7": return .input("\u{1B}[18~")
        case "f8": return .input("\u{1B}[19~")
        case "f9": return .input("\u{1B}[20~")
        case "f10": return .input("\u{1B}[21~")
        case "f11": return .input("\u{1B}[23~")
        case "f12": return .input("\u{1B}[24~")
        case "f13": return .input("\u{1B}[25~")
        case "f14": return .input("\u{1B}[26~")
        case "f15", "help": return .input("\u{1B}[28~")
        case "f16": return .input("\u{1B}[29~")
        case "f17": return .input("\u{1B}[31~")
        case "f18": return .input("\u{1B}[32~")
        case "f19": return .input("\u{1B}[33~")
        case "f20": return .input("\u{1B}[34~")
        case "keypad_pf1", "kp_pf1":
            return .input("\u{1B}OP")
        case "keypad_pf2", "kp_pf2":
            return .input("\u{1B}OQ")
        case "keypad_pf3", "kp_pf3":
            return .input("\u{1B}OR")
        case "keypad_pf4", "kp_pf4":
            return .input("\u{1B}OS")
        case "keypad_0", "kp_0":
            return .input(namedKeypadSequence(numeric: "0", application: "\u{1B}Op", controller: controller))
        case "keypad_1", "kp_1":
            return .input(namedKeypadSequence(numeric: "1", application: "\u{1B}Oq", controller: controller))
        case "keypad_2", "kp_2":
            return .input(namedKeypadSequence(numeric: "2", application: "\u{1B}Or", controller: controller))
        case "keypad_3", "kp_3":
            return .input(namedKeypadSequence(numeric: "3", application: "\u{1B}Os", controller: controller))
        case "keypad_4", "kp_4":
            return .input(namedKeypadSequence(numeric: "4", application: "\u{1B}Ot", controller: controller))
        case "keypad_5", "kp_5":
            return .input(namedKeypadSequence(numeric: "5", application: "\u{1B}Ou", controller: controller))
        case "keypad_6", "kp_6":
            return .input(namedKeypadSequence(numeric: "6", application: "\u{1B}Ov", controller: controller))
        case "keypad_7", "kp_7":
            return .input(namedKeypadSequence(numeric: "7", application: "\u{1B}Ow", controller: controller))
        case "keypad_8", "kp_8":
            return .input(namedKeypadSequence(numeric: "8", application: "\u{1B}Ox", controller: controller))
        case "keypad_9", "kp_9":
            return .input(namedKeypadSequence(numeric: "9", application: "\u{1B}Oy", controller: controller))
        case "keypad_plus", "kp_plus":
            return .input(namedKeypadSequence(numeric: "+", application: "\u{1B}Ok", controller: controller))
        case "keypad_multiply", "kp_multiply":
            return .input(namedKeypadSequence(numeric: "*", application: "\u{1B}Oj", controller: controller))
        case "keypad_divide", "kp_divide":
            return .input(namedKeypadSequence(numeric: "/", application: "\u{1B}Oo", controller: controller))
        case "keypad_minus", "kp_minus":
            return .input(namedKeypadSequence(numeric: "-", application: "\u{1B}Om", controller: controller))
        case "keypad_decimal", "kp_decimal":
            return .input(namedKeypadSequence(numeric: ".", application: "\u{1B}On", controller: controller))
        case "keypad_enter", "kp_enter":
            return .input(namedKeypadSequence(numeric: "\r", application: "\u{1B}OM", controller: controller))
        case "ctrl_c", "control_c":
            return .input(String(UnicodeScalar(0x03)!))
        case "ctrl_z", "control_z":
            return .input(String(UnicodeScalar(0x1A)!))
        case "ctrl_backslash", "control_backslash":
            return .input(String(UnicodeScalar(0x1C)!))
        case "ctrl_space", "control_space", "ctrl_at", "control_at":
            return .input(String(UnicodeScalar(0x00)!))
        case "ctrl_left_bracket", "control_left_bracket":
            return .input("\u{1B}")
        case "ctrl_right_bracket", "control_right_bracket":
            return .input(String(UnicodeScalar(0x1D)!))
        case "ctrl_caret", "control_caret", "ctrl_tilde", "control_tilde", "ctrl_backtick", "control_backtick":
            return .input(String(UnicodeScalar(0x1E)!))
        case "ctrl_underscore", "control_underscore", "ctrl_question_mark", "control_question_mark":
            return .input(String(UnicodeScalar(0x1F)!))
        default:
            if let controlAction = mcpControlCharacterAction(for: key) {
                return controlAction
            }
            return nil
        }
    }

    private static func namedArrowSequence(letter: String, controller: TerminalController) -> String {
        let appCursor = controller.withModel { $0.applicationCursorKeys }
        let prefix = appCursor ? "\u{1B}O" : "\u{1B}["
        return "\(prefix)\(letter)"
    }

    private static func namedKeypadSequence(numeric: String, application: String, controller: TerminalController) -> String {
        let appKeypad = controller.withModel { $0.applicationKeypadMode }
        return appKeypad ? application : numeric
    }

    private static func mcpControlCharacterAction(for key: String) -> MCPKeyAction? {
        let prefixes = ["ctrl_", "control_"]
        guard let prefix = prefixes.first(where: { key.hasPrefix($0) }) else {
            return nil
        }
        let suffix = key.dropFirst(prefix.count)
        guard suffix.count == 1, let scalar = suffix.unicodeScalars.first else {
            return nil
        }
        let value = scalar.value
        guard value >= 0x61 && value <= 0x7A else {
            return nil
        }
        return .input(String(UnicodeScalar(value - 0x60)!))
    }

    private func translatedSpecialKeyInput(
        for event: NSEvent,
        applicationCursorKeys appCursor: Bool,
        applicationKeypadMode appKeypad: Bool
    ) -> String? {
        let prefix: String = appCursor ? "\u{1B}O" : "\u{1B}["
        let relevantModifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let modifierParameter = xtermModifierParameter(for: relevantModifiers)
        let hasExplicitModifiers = modifierParameter != 1

        if appKeypad, let keypadSequence = applicationKeypadSequence(for: event) {
            return keypadSequence
        }

        switch event.keyCode {
        case 126: // Up
            return hasExplicitModifiers ? "\u{1B}[1;\(modifierParameter)A" : "\(prefix)A"
        case 125: // Down
            return hasExplicitModifiers ? "\u{1B}[1;\(modifierParameter)B" : "\(prefix)B"
        case 124: // Right
            return hasExplicitModifiers ? "\u{1B}[1;\(modifierParameter)C" : "\(prefix)C"
        case 123: // Left
            return hasExplicitModifiers ? "\u{1B}[1;\(modifierParameter)D" : "\(prefix)D"
        case 115: // Home
            return hasExplicitModifiers ? "\u{1B}[1;\(modifierParameter)H" : (appCursor ? "\u{1B}OH" : "\u{1B}[H")
        case 119: // End
            return hasExplicitModifiers ? "\u{1B}[1;\(modifierParameter)F" : (appCursor ? "\u{1B}OF" : "\u{1B}[F")
        case 116: // PageUp
            return hasExplicitModifiers ? "\u{1B}[5;\(modifierParameter)~" : "\u{1B}[5~"
        case 121: // PageDown
            return hasExplicitModifiers ? "\u{1B}[6;\(modifierParameter)~" : "\u{1B}[6~"
        case 117: // Delete (forward)
            return hasExplicitModifiers ? "\u{1B}[3;\(modifierParameter)~" : "\u{1B}[3~"
        case 51: // Backspace
            if hasExplicitModifiers {
                return "\u{1B}[127;\(modifierParameter)u"
            }
            return String(UnicodeScalar(0x7F)!)
        case 53: // Escape
            if hasExplicitModifiers {
                return "\u{1B}[27;\(modifierParameter)u"
            }
            return "\u{1B}"
        case 76: // Enter (numpad)
            if hasExplicitModifiers {
                return "\u{1B}[13;\(modifierParameter)u"
            }
            return "\r"
        case 36: // Return
            if hasExplicitModifiers {
                return "\u{1B}[13;\(modifierParameter)u"
            }
            return "\r"
        case 48: // Tab
            if hasExplicitModifiers {
                return "\u{1B}[9;\(modifierParameter)u"
            }
            if event.modifierFlags.contains(.shift) {
                return "\u{1B}[Z" // Backtab
            }
            return "\t"
        // Function keys
        case UInt16(kVK_F1): return hasExplicitModifiers ? "\u{1B}[11;\(modifierParameter)~" : "\u{1B}[11~"
        case UInt16(kVK_F2): return hasExplicitModifiers ? "\u{1B}[12;\(modifierParameter)~" : "\u{1B}[12~"
        case UInt16(kVK_F3): return hasExplicitModifiers ? "\u{1B}[13;\(modifierParameter)~" : "\u{1B}[13~"
        case UInt16(kVK_F4): return hasExplicitModifiers ? "\u{1B}[14;\(modifierParameter)~" : "\u{1B}[14~"
        case 96:  return hasExplicitModifiers ? "\u{1B}[15;\(modifierParameter)~" : "\u{1B}[15~"
        case 97:  return hasExplicitModifiers ? "\u{1B}[17;\(modifierParameter)~" : "\u{1B}[17~"
        case 98:  return hasExplicitModifiers ? "\u{1B}[18;\(modifierParameter)~" : "\u{1B}[18~"
        case 100: return hasExplicitModifiers ? "\u{1B}[19;\(modifierParameter)~" : "\u{1B}[19~"
        case 101: return hasExplicitModifiers ? "\u{1B}[20;\(modifierParameter)~" : "\u{1B}[20~"
        case UInt16(kVK_F10): return hasExplicitModifiers ? "\u{1B}[21;\(modifierParameter)~" : "\u{1B}[21~"
        case UInt16(kVK_F11): return hasExplicitModifiers ? "\u{1B}[23;\(modifierParameter)~" : "\u{1B}[23~"
        case UInt16(kVK_F12): return hasExplicitModifiers ? "\u{1B}[24;\(modifierParameter)~" : "\u{1B}[24~"
        case UInt16(kVK_F13): return hasExplicitModifiers ? "\u{1B}[25;\(modifierParameter)~" : "\u{1B}[25~"
        case UInt16(kVK_F14): return hasExplicitModifiers ? "\u{1B}[26;\(modifierParameter)~" : "\u{1B}[26~"
        case UInt16(kVK_F15), UInt16(kVK_Help): return hasExplicitModifiers ? "\u{1B}[28;\(modifierParameter)~" : "\u{1B}[28~"
        case UInt16(kVK_F16): return hasExplicitModifiers ? "\u{1B}[29;\(modifierParameter)~" : "\u{1B}[29~"
        case UInt16(kVK_F17): return hasExplicitModifiers ? "\u{1B}[31;\(modifierParameter)~" : "\u{1B}[31~"
        case UInt16(kVK_F18): return hasExplicitModifiers ? "\u{1B}[32;\(modifierParameter)~" : "\u{1B}[32~"
        case UInt16(kVK_F19): return hasExplicitModifiers ? "\u{1B}[33;\(modifierParameter)~" : "\u{1B}[33~"
        case UInt16(kVK_F20): return hasExplicitModifiers ? "\u{1B}[34;\(modifierParameter)~" : "\u{1B}[34~"
        default:
            return nil
        }
    }

    private func xtermModifierParameter(for modifiers: NSEvent.ModifierFlags) -> Int {
        var value = 1
        if modifiers.contains(.shift) { value += 1 }
        if modifiers.contains(.option) { value += 2 }
        if modifiers.contains(.control) { value += 4 }
        if modifiers.contains(.command) { value += 8 }
        return value
    }

    private func modifyOtherKeysInputSequence(
        for event: NSEvent,
        mode: Int,
        format: Int,
        factoredModifierMask: Int
    ) -> String? {
        guard mode > 0 else { return nil }

        let relevantModifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let rawModifierBits = modifierBitmask(for: relevantModifiers)
        let shouldEncode: Bool
        switch mode {
        case 1:
            let nonTraditionalModifiers = rawModifierBits & ~(ModifierBit.shift.rawValue | ModifierBit.control.rawValue)
            shouldEncode = nonTraditionalModifiers != 0
        case 2:
            shouldEncode = rawModifierBits != 0
        case 3:
            shouldEncode = true
        default:
            shouldEncode = false
        }
        guard shouldEncode else { return nil }

        guard let codepoint = ordinaryKeyCodepoint(for: event, modifiers: relevantModifiers) else {
            return nil
        }

        let encodedModifierBits = rawModifierBits & ~max(factoredModifierMask, 0)
        let modifierParameter = encodedModifierBits + 1
        if format == 1 {
            return "\u{1B}[\(codepoint);\(modifierParameter)u"
        }
        return "\u{1B}[27;\(modifierParameter);\(codepoint)~"
    }

    private enum ModifierBit: Int {
        case shift = 1
        case option = 2
        case control = 4
        case command = 8
    }

    private func modifierBitmask(for modifiers: NSEvent.ModifierFlags) -> Int {
        var mask = 0
        if modifiers.contains(.shift) { mask |= ModifierBit.shift.rawValue }
        if modifiers.contains(.option) { mask |= ModifierBit.option.rawValue }
        if modifiers.contains(.control) { mask |= ModifierBit.control.rawValue }
        if modifiers.contains(.command) { mask |= ModifierBit.command.rawValue }
        return mask
    }

    private func ordinaryKeyCodepoint(
        for event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> UInt32? {
        switch event.keyCode {
        case 48:
            return 9
        case 36, 76:
            return 13
        case 53:
            return 27
        case 51:
            return 127
        default:
            break
        }

        let source: String?
        if modifiers.contains(.control) {
            source = event.charactersIgnoringModifiers
        } else {
            source = event.characters
        }

        guard let source,
              let scalar = source.unicodeScalars.first
        else {
            return nil
        }
        return scalar.value
    }

    private func kittyKeyboardInputSequence(for event: NSEvent) -> String? {
        let relevantModifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if let special = kittySpecialKeySequence(for: event, modifiers: relevantModifiers) {
            return special
        }

        guard let chars = event.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first
        else {
            return nil
        }

        if relevantModifiers.isEmpty {
            return nil
        }

        let modifierValue = kittyModifierValue(for: relevantModifiers)
        return "\u{1B}[\(scalar.value);\(modifierValue)u"
    }

    private func kittyModifierValue(for modifiers: NSEvent.ModifierFlags) -> Int {
        var value = 1
        if modifiers.contains(.shift) { value += 1 }
        if modifiers.contains(.option) { value += 2 }
        if modifiers.contains(.control) { value += 4 }
        if modifiers.contains(.command) { value += 8 }
        return value
    }

    private func kittySpecialKeySequence(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> String? {
        let modifierValue = kittyModifierValue(for: modifiers)
        let hasExplicitModifiers = modifierValue != 1

        switch event.keyCode {
        case UInt16(kVK_F1): return hasExplicitModifiers ? "\u{1B}[11;\(modifierValue)~" : nil
        case UInt16(kVK_F2): return hasExplicitModifiers ? "\u{1B}[12;\(modifierValue)~" : nil
        case UInt16(kVK_F3): return hasExplicitModifiers ? "\u{1B}[13;\(modifierValue)~" : nil
        case UInt16(kVK_F4): return hasExplicitModifiers ? "\u{1B}[14;\(modifierValue)~" : nil
        case 96: return hasExplicitModifiers ? "\u{1B}[15;\(modifierValue)~" : nil
        case 97: return hasExplicitModifiers ? "\u{1B}[17;\(modifierValue)~" : nil
        case 98: return hasExplicitModifiers ? "\u{1B}[18;\(modifierValue)~" : nil
        case 100: return hasExplicitModifiers ? "\u{1B}[19;\(modifierValue)~" : nil
        case 101: return hasExplicitModifiers ? "\u{1B}[20;\(modifierValue)~" : nil
        case UInt16(kVK_F10): return hasExplicitModifiers ? "\u{1B}[21;\(modifierValue)~" : nil
        case UInt16(kVK_F11): return hasExplicitModifiers ? "\u{1B}[23;\(modifierValue)~" : nil
        case UInt16(kVK_F12): return hasExplicitModifiers ? "\u{1B}[24;\(modifierValue)~" : nil
        case UInt16(kVK_F13): return hasExplicitModifiers ? "\u{1B}[25;\(modifierValue)~" : nil
        case UInt16(kVK_F14): return hasExplicitModifiers ? "\u{1B}[26;\(modifierValue)~" : nil
        case UInt16(kVK_F15), UInt16(kVK_Help): return hasExplicitModifiers ? "\u{1B}[28;\(modifierValue)~" : nil
        case UInt16(kVK_F16): return hasExplicitModifiers ? "\u{1B}[29;\(modifierValue)~" : nil
        case UInt16(kVK_F17): return hasExplicitModifiers ? "\u{1B}[31;\(modifierValue)~" : nil
        case UInt16(kVK_F18): return hasExplicitModifiers ? "\u{1B}[32;\(modifierValue)~" : nil
        case UInt16(kVK_F19): return hasExplicitModifiers ? "\u{1B}[33;\(modifierValue)~" : nil
        case UInt16(kVK_F20): return hasExplicitModifiers ? "\u{1B}[34;\(modifierValue)~" : nil
        case 126: return hasExplicitModifiers ? "\u{1B}[1;\(modifierValue)A" : nil
        case 125: return hasExplicitModifiers ? "\u{1B}[1;\(modifierValue)B" : nil
        case 124: return hasExplicitModifiers ? "\u{1B}[1;\(modifierValue)C" : nil
        case 123: return hasExplicitModifiers ? "\u{1B}[1;\(modifierValue)D" : nil
        case 115: return hasExplicitModifiers ? "\u{1B}[1;\(modifierValue)H" : nil
        case 119: return hasExplicitModifiers ? "\u{1B}[1;\(modifierValue)F" : nil
        case 116: return hasExplicitModifiers ? "\u{1B}[5;\(modifierValue)~" : nil
        case 121: return hasExplicitModifiers ? "\u{1B}[6;\(modifierValue)~" : nil
        case 117: return hasExplicitModifiers ? "\u{1B}[3;\(modifierValue)~" : nil
        case 51:
            return hasExplicitModifiers ? "\u{1B}[127;\(modifierValue)u" : nil
        case 53:
            return hasExplicitModifiers ? "\u{1B}[27;\(modifierValue)u" : nil
        case 36, 76:
            return hasExplicitModifiers ? "\u{1B}[13;\(modifierValue)u" : nil
        case 48:
            return hasExplicitModifiers ? "\u{1B}[9;\(modifierValue)u" : nil
        default:
            return nil
        }
    }

    private func applicationKeypadSequence(for event: NSEvent) -> String? {
        switch event.keyCode {
        case UInt16(kVK_ANSI_Keypad0): return "\u{1B}Op"
        case UInt16(kVK_ANSI_Keypad1): return "\u{1B}Oq"
        case UInt16(kVK_ANSI_Keypad2): return "\u{1B}Or"
        case UInt16(kVK_ANSI_Keypad3): return "\u{1B}Os"
        case UInt16(kVK_ANSI_Keypad4): return "\u{1B}Ot"
        case UInt16(kVK_ANSI_Keypad5): return "\u{1B}Ou"
        case UInt16(kVK_ANSI_Keypad6): return "\u{1B}Ov"
        case UInt16(kVK_ANSI_Keypad7): return "\u{1B}Ow"
        case UInt16(kVK_ANSI_Keypad8): return "\u{1B}Ox"
        case UInt16(kVK_ANSI_Keypad9): return "\u{1B}Oy"
        case UInt16(kVK_ANSI_KeypadPlus): return "\u{1B}Ok"
        case UInt16(kVK_ANSI_KeypadMultiply): return "\u{1B}Oj"
        case UInt16(kVK_ANSI_KeypadDivide): return "\u{1B}Oo"
        case UInt16(kVK_ANSI_KeypadMinus): return "\u{1B}Om"
        case UInt16(kVK_ANSI_KeypadDecimal): return "\u{1B}On"
        case UInt16(kVK_ANSI_KeypadEquals): return "\u{1B}OX"
        case UInt16(kVK_ANSI_KeypadEnter): return "\u{1B}OM"
        default: return nil
        }
    }
}

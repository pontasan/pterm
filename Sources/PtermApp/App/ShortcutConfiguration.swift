import AppKit
import Foundation

enum ShortcutAction: String, CaseIterable {
    case newTerminal = "new_terminal"
    case backToIntegrated = "back_to_integrated"
    case focusTerminal1 = "focus_terminal_1"
    case focusTerminal2 = "focus_terminal_2"
    case focusTerminal3 = "focus_terminal_3"
    case focusTerminal4 = "focus_terminal_4"
    case focusTerminal5 = "focus_terminal_5"
    case focusTerminal6 = "focus_terminal_6"
    case focusTerminal7 = "focus_terminal_7"
    case focusTerminal8 = "focus_terminal_8"
    case focusTerminal9 = "focus_terminal_9"
    case focusPreviousTerminal = "focus_previous_terminal"
    case focusNextTerminal = "focus_next_terminal"
    case selectAll = "select_all"
    case find = "find"
    case findNext = "find_next"
    case findPrevious = "find_previous"
    case copy = "copy"
    case paste = "paste"
    case cut = "cut"
    case closeTerminal = "close_terminal"
    case quit = "quit"
    case openSettings = "open_settings"
    case newWindow = "new_window"
    case undo = "undo"
    case clearScreen = "clear_screen"
    case scrollToTop = "scroll_to_top"
    case zoomIn = "zoom_in"
    case zoomOut = "zoom_out"
    case zoomReset = "zoom_reset"

    static var focusActions: [ShortcutAction] {
        [.focusTerminal1, .focusTerminal2, .focusTerminal3, .focusTerminal4, .focusTerminal5,
         .focusTerminal6, .focusTerminal7, .focusTerminal8, .focusTerminal9]
    }
}

struct KeyboardShortcut {
    private static let supportedModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    enum Trigger: Equatable {
        case character(String)
        case keyCode(UInt16)
    }

    var modifiers: NSEvent.ModifierFlags
    var trigger: Trigger

    func matches(_ event: NSEvent) -> Bool {
        let eventModifiers = event.modifierFlags.intersection(Self.supportedModifierMask)
        guard eventModifiers == modifiers else { return false }

        switch trigger {
        case .character(let value):
            return event.charactersIgnoringModifiers?.lowercased() == value.lowercased()
        case .keyCode(let keyCode):
            return event.keyCode == keyCode
        }
    }

    var menuKeyEquivalent: String {
        switch trigger {
        case .character(let value):
            return value
        case .keyCode(let keyCode):
            switch keyCode {
            case 50: return "`"
            case 53: return "\u{1B}"
            case 123: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case 124: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
            default: return ""
            }
        }
    }
}

struct ShortcutBinding {
    var primary: KeyboardShortcut
    var alternates: [KeyboardShortcut] = []

    func matches(_ event: NSEvent) -> Bool {
        primary.matches(event) || alternates.contains(where: { $0.matches(event) })
    }
}

struct ShortcutConfiguration {
    private let bindings: [ShortcutAction: ShortcutBinding]

    init(bindings: [ShortcutAction: ShortcutBinding] = ShortcutConfiguration.defaultBindings) {
        self.bindings = bindings
    }

    func binding(for action: ShortcutAction) -> ShortcutBinding {
        bindings[action] ?? Self.defaultBindings[action]!
    }

    func matches(_ action: ShortcutAction, event: NSEvent) -> Bool {
        binding(for: action).matches(event)
    }

    static let `default` = ShortcutConfiguration()

    private static let defaultBindings: [ShortcutAction: ShortcutBinding] = [
        .newTerminal: .init(primary: command("t")),
        .backToIntegrated: .init(primary: commandKeyCode(50)),  // Cmd+` (backtick)
        .focusTerminal1: .init(primary: command("1")),
        .focusTerminal2: .init(primary: command("2")),
        .focusTerminal3: .init(primary: command("3")),
        .focusTerminal4: .init(primary: command("4")),
        .focusTerminal5: .init(primary: command("5")),
        .focusTerminal6: .init(primary: command("6")),
        .focusTerminal7: .init(primary: command("7")),
        .focusTerminal8: .init(primary: command("8")),
        .focusTerminal9: .init(primary: command("9")),
        .focusPreviousTerminal: .init(primary: commandKeyCode(123)),
        .focusNextTerminal: .init(primary: commandKeyCode(124)),
        .selectAll: .init(primary: command("a")),
        .find: .init(primary: command("f")),
        .findNext: .init(primary: command("g")),
        .findPrevious: .init(primary: shiftCommand("g")),
        .copy: .init(primary: command("c")),
        .paste: .init(primary: command("v")),
        .cut: .init(primary: command("x")),
        .closeTerminal: .init(primary: command("w")),
        .quit: .init(primary: command("q")),
        .openSettings: .init(primary: command(",")),
        .newWindow: .init(primary: command("n")),
        .undo: .init(primary: command("z")),
        .clearScreen: .init(primary: command("k")),
        .scrollToTop: .init(primary: command("l")),
        .zoomIn: .init(primary: command("="), alternates: [shiftCommand("=")]),
        .zoomOut: .init(primary: command("-")),
        .zoomReset: .init(primary: command("0"))
    ]

    private static func command(_ character: String) -> KeyboardShortcut {
        KeyboardShortcut(modifiers: [.command], trigger: .character(character))
    }

    private static func shiftCommand(_ character: String) -> KeyboardShortcut {
        KeyboardShortcut(modifiers: [.command, .shift], trigger: .character(character))
    }

    private static func commandKeyCode(_ keyCode: UInt16) -> KeyboardShortcut {
        KeyboardShortcut(modifiers: [.command], trigger: .keyCode(keyCode))
    }
}

enum ShortcutParser {
    static func parseMap(_ rawMap: [String: String]?) -> ShortcutConfiguration {
        guard let rawMap else { return .default }
        let bindings = ShortcutConfiguration.default
        var resolved: [ShortcutAction: ShortcutBinding] = [:]

        for action in ShortcutAction.allCases {
            guard let raw = rawMap[action.rawValue],
                  let shortcut = parse(raw) else {
                resolved[action] = bindings.binding(for: action)
                continue
            }
            resolved[action] = shortcut
        }

        return ShortcutConfiguration(bindings: resolved)
    }

    private static func parse(_ raw: String) -> ShortcutBinding? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var normalized = trimmed.replacingOccurrences(of: "Command", with: "Cmd")
        normalized = normalized.replacingOccurrences(of: "Option", with: "Alt")
        normalized = normalized.replacingOccurrences(of: "Control", with: "Ctrl")

        let keyToken: String
        let modifierSegment: String
        if normalized.hasSuffix("++") {
            keyToken = "+"
            modifierSegment = String(normalized.dropLast())
        } else {
            let parts = normalized.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            guard let last = parts.last, !last.isEmpty else { return nil }
            keyToken = last
            modifierSegment = parts.dropLast().joined(separator: "+")
        }

        var modifiers: NSEvent.ModifierFlags = []
        for token in modifierSegment.split(separator: "+").map(String.init) where !token.isEmpty {
            switch token.lowercased() {
            case "cmd":
                modifiers.insert(.command)
            case "shift":
                modifiers.insert(.shift)
            case "alt", "option":
                modifiers.insert(.option)
            case "ctrl", "control":
                modifiers.insert(.control)
            default:
                return nil
            }
        }

        let lowered = keyToken.lowercased()
        let shortcut: KeyboardShortcut
        switch lowered {
        case "esc", "escape":
            shortcut = KeyboardShortcut(modifiers: modifiers, trigger: .keyCode(53))
        case "left", "arrowleft":
            shortcut = KeyboardShortcut(modifiers: modifiers, trigger: .keyCode(123))
        case "right", "arrowright":
            shortcut = KeyboardShortcut(modifiers: modifiers, trigger: .keyCode(124))
        case "+", "plus":
            shortcut = KeyboardShortcut(modifiers: modifiers.union(.shift), trigger: .character("="))
        default:
            guard lowered.count == 1 else { return nil }
            shortcut = KeyboardShortcut(modifiers: modifiers, trigger: .character(lowered))
        }

        guard shortcut.modifiers.contains(.command) else {
            return nil
        }

        return ShortcutBinding(primary: shortcut)
    }
}

extension ShortcutAction {
    var appDelegateSelector: Selector? {
        switch self {
        case .newTerminal:
            return #selector(AppDelegate.newTerminal(_:))
        case .backToIntegrated:
            return #selector(AppDelegate.backToIntegratedView(_:))
        case .focusTerminal1, .focusTerminal2, .focusTerminal3, .focusTerminal4, .focusTerminal5,
             .focusTerminal6, .focusTerminal7, .focusTerminal8, .focusTerminal9:
            return #selector(AppDelegate.focusTerminalByShortcut(_:))
        case .focusPreviousTerminal:
            return #selector(AppDelegate.focusPreviousTerminal(_:))
        case .focusNextTerminal:
            return #selector(AppDelegate.focusNextTerminal(_:))
        case .selectAll:
            return #selector(AppDelegate.selectAll(_:))
        case .find:
            return #selector(AppDelegate.performFindPanelAction(_:))
        case .findNext:
            return #selector(AppDelegate.findNextMatch(_:))
        case .findPrevious:
            return #selector(AppDelegate.findPreviousMatch(_:))
        case .copy:
            return #selector(AppDelegate.copy(_:))
        case .paste:
            return #selector(AppDelegate.paste(_:))
        case .cut:
            return #selector(AppDelegate.cut(_:))
        case .closeTerminal:
            return #selector(AppDelegate.closeCurrentTerminal(_:))
        case .quit:
            return #selector(NSApplication.terminate(_:))
        case .openSettings:
            return #selector(AppDelegate.openSettings(_:))
        case .newWindow:
            return #selector(AppDelegate.newWindowReserved(_:))
        case .undo:
            return #selector(AppDelegate.undoTextInput(_:))
        case .clearScreen:
            return #selector(AppDelegate.clearActiveTerminalScreen(_:))
        case .scrollToTop:
            return #selector(AppDelegate.scrollActiveTerminalToTop(_:))
        case .zoomIn:
            return #selector(AppDelegate.fontSizeIncrease(_:))
        case .zoomOut:
            return #selector(AppDelegate.fontSizeDecrease(_:))
        case .zoomReset:
            return #selector(AppDelegate.fontSizeReset(_:))
        }
    }
}

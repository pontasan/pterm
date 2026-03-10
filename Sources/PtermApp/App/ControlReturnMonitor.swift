import AppKit
import AVFoundation
import Foundation
import UserNotifications

enum ControlReturnMode: String, Equatable {
    case speech
    case sound
    case both
    case none
}

struct NotificationConfiguration: Equatable {
    var controlReturn: ControlReturnMode
    var customSound: String?

    static let `default` = NotificationConfiguration(controlReturn: .speech, customSound: nil)
}

final class ControlReturnMonitor {
    struct TerminalSnapshot {
        let id: UUID
        let pid: pid_t
        let displayName: String
    }

    var onStateChange: ((Set<UUID>) -> Void)?

    private struct State {
        var lastOutputAt: Date
        var announced = false
        var displayName: String
        var pid: pid_t
    }

    private let interval: TimeInterval
    private let idleThreshold: TimeInterval
    private let processStateProvider: (pid_t) -> Bool
    private let nowProvider: () -> Date
    private let modeProvider: () -> NotificationConfiguration
    private var timer: Timer?
    private var states: [UUID: State] = [:]
    private var highlighted: Set<UUID> = []
    private let speechSynthesizer = AVSpeechSynthesizer()

    init(interval: TimeInterval = 2.0,
         idleThreshold: TimeInterval = 6.0,
         processStateProvider: @escaping (pid_t) -> Bool = ControlReturnMonitor.isMainThreadIdleWaitState(pid:),
         nowProvider: @escaping () -> Date = Date.init,
         modeProvider: @escaping () -> NotificationConfiguration) {
        self.interval = interval
        self.idleThreshold = idleThreshold
        self.processStateProvider = processStateProvider
        self.nowProvider = nowProvider
        self.modeProvider = modeProvider
    }

    func start(terminalsProvider: @escaping () -> [TerminalSnapshot]) {
        stop()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.evaluate(terminals: terminalsProvider())
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        evaluate(terminals: terminalsProvider())
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        highlighted.removeAll()
        states.removeAll()
    }

    func noteOutput(for terminalID: UUID, pid: pid_t, displayName: String) {
        states[terminalID] = State(lastOutputAt: nowProvider(), announced: false,
                                   displayName: displayName, pid: pid)
        if highlighted.remove(terminalID) != nil {
            onStateChange?(highlighted)
        }
    }

    private func evaluate(terminals: [TerminalSnapshot]) {
        let terminalIDs = Set(terminals.map(\.id))
        states = states.filter { terminalIDs.contains($0.key) }
        let now = nowProvider()
        var nextHighlighted = highlighted

        for terminal in terminals {
            var state = states[terminal.id] ?? State(lastOutputAt: now, displayName: terminal.displayName, pid: terminal.pid)
            state.displayName = terminal.displayName
            state.pid = terminal.pid
            let idle = now.timeIntervalSince(state.lastOutputAt)
            let waiting = processStateProvider(terminal.pid)
            if idle >= idleThreshold && waiting && !state.announced {
                state.announced = true
                nextHighlighted.insert(terminal.id)
                announce(displayName: terminal.displayName)
            } else if idle < idleThreshold || !waiting {
                state.announced = false
                nextHighlighted.remove(terminal.id)
            }
            states[terminal.id] = state
        }

        if nextHighlighted != highlighted {
            highlighted = nextHighlighted
            onStateChange?(highlighted)
        }
    }

    private func announce(displayName: String) {
        let configuration = modeProvider()
        guard configuration.controlReturn != .none else { return }

        if NSApp.isActive {
            return
        }

        let message = "\(displayName) の制御が戻りました"
        if configuration.controlReturn == .speech || configuration.controlReturn == .both {
            let utterance = AVSpeechUtterance(string: message)
            speechSynthesizer.speak(utterance)
        }
        if configuration.controlReturn == .sound || configuration.controlReturn == .both {
            if let sound = makeNotificationSound(from: configuration.customSound) {
                sound.play()
            } else {
                NSSound.beep()
            }
        }

        let content = UNMutableNotificationContent()
        content.title = "pterm"
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func makeNotificationSound(from configuredValue: String?) -> NSSound? {
        guard let configuredValue,
              !configuredValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let expanded = (configuredValue as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let url = URL(fileURLWithPath: expanded)
            if FileManager.default.fileExists(atPath: url.path) {
                return NSSound(contentsOf: url, byReference: false)
            }
            return nil
        }

        return NSSound(named: NSSound.Name(configuredValue))
    }

    private static func isMainThreadIdleWaitState(pid: pid_t) -> Bool {
        guard let mainThreadID = mainThreadID(for: pid) else { return false }

        var threadInfo = proc_threadinfo()
        let threadSize = proc_pidinfo(
            pid,
            PROC_PIDTHREADINFO,
            mainThreadID,
            &threadInfo,
            Int32(MemoryLayout<proc_threadinfo>.stride)
        )
        guard threadSize == Int32(MemoryLayout<proc_threadinfo>.stride) else {
            return false
        }

        return
            threadInfo.pth_run_state == TH_STATE_WAITING ||
            threadInfo.pth_run_state == TH_STATE_UNINTERRUPTIBLE
    }

    private static func mainThreadID(for pid: pid_t) -> UInt64? {
        var threadIDs = [UInt64](repeating: 0, count: 16)

        while true {
            let bufferSize = Int32(MemoryLayout<UInt64>.stride * threadIDs.count)
            let bytes = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &threadIDs, bufferSize)
            guard bytes > 0 else { return nil }

            let count = Int(bytes) / MemoryLayout<UInt64>.stride
            if count == 0 {
                return nil
            }
            if count < threadIDs.count {
                return threadIDs[0]
            }

            threadIDs.append(contentsOf: repeatElement(0, count: threadIDs.count))
        }
    }
}

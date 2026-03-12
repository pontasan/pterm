import Foundation

enum AtomicFileWriter {
    static func write(_ data: Data, to destination: URL, permissions: Int = 0o600) throws {
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let created = fm.createFile(atPath: tempURL.path, contents: data,
                                    attributes: [.posixPermissions: permissions])
        guard created else {
            throw CocoaError(.fileWriteUnknown)
        }

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: destination)
        }
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
    }
}

final class CoalescedCallback {
    private let callback: () -> Void
    private let lock = NSLock()
    private var batchDepth = 0
    private var pendingSignal = false

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func signal() {
        let shouldCallbackImmediately = lock.withLock { () -> Bool in
            if batchDepth > 0 {
                pendingSignal = true
                return false
            }
            return true
        }

        if shouldCallbackImmediately {
            callback()
        }
    }

    func performBatch(_ updates: () -> Void) {
        lock.withLock {
            batchDepth += 1
        }

        updates()

        let shouldCallback = lock.withLock { () -> Bool in
            batchDepth -= 1
            guard batchDepth == 0, pendingSignal else { return false }
            pendingSignal = false
            return true
        }

        if shouldCallback {
            callback()
        }
    }
}

final class DebouncedActionCoordinator {
    private let debounceInterval: TimeInterval
    private let scheduleQueue: DispatchQueue
    private let action: () -> Void
    private let lock = NSLock()
    private var pendingWorkItem: DispatchWorkItem?

    init(
        debounceInterval: TimeInterval,
        scheduleQueue: DispatchQueue = .main,
        action: @escaping () -> Void
    ) {
        self.debounceInterval = debounceInterval
        self.scheduleQueue = scheduleQueue
        self.action = action
    }

    func schedule() {
        var scheduledWorkItem: DispatchWorkItem?
        let workItem = DispatchWorkItem { [weak self] in
            self?.runPending(workItem: scheduledWorkItem)
        }
        scheduledWorkItem = workItem

        lock.withLock {
            pendingWorkItem?.cancel()
            pendingWorkItem = workItem
        }

        scheduleQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    func flush() {
        let shouldRun = lock.withLock { () -> Bool in
            let hadPending = pendingWorkItem != nil
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
            return hadPending
        }

        if shouldRun {
            action()
        }
    }

    func cancel() {
        lock.withLock {
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
        }
    }

    private func runPending(workItem: DispatchWorkItem?) {
        let shouldRun = lock.withLock { () -> Bool in
            guard let pendingWorkItem else { return false }
            if let workItem, pendingWorkItem !== workItem {
                return false
            }
            self.pendingWorkItem = nil
            return !pendingWorkItem.isCancelled
        }

        if shouldRun {
            action()
        }
    }
}

enum FileNameSanitizer {
    static func sanitize(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed.map { character -> Character in
            if character == "/" || character == ":" || character.isNewline {
                return "_"
            }
            return character
        }
        let result = String(sanitized).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

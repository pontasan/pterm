import Foundation

final class ClipboardCleanupService {
    private let fileStore: ClipboardFileStore
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "pterm.clipboard.cleanup", qos: .utility)
    private var timer: DispatchSourceTimer?

    init(fileStore: ClipboardFileStore, interval: TimeInterval = 60 * 60) {
        self.fileStore = fileStore
        self.interval = interval
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [fileStore] in
            do {
                try fileStore.cleanupExpiredFiles()
            } catch {
                NSLog("pterm clipboard cleanup failed: %@", String(describing: error))
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

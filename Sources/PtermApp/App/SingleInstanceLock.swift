import AppKit
import Foundation

final class SingleInstanceLock {
    private let lockURL: URL
    private let notificationCenter = DistributedNotificationCenter.default()
    private var lockFD: Int32 = -1

    static let activationNotification = Notification.Name("com.pterm.activate-existing-instance")

    init(lockURL: URL = PtermDirectories.lock) {
        self.lockURL = lockURL
    }

    deinit {
        release()
    }

    func acquireOrActivateExisting() throws -> Bool {
        let fm = FileManager.default
        let directory = lockURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: lockURL.path) {
            fm.createFile(atPath: lockURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        let fd = open(lockURL.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd
            return true
        }

        close(fd)
        notificationCenter.post(name: Self.activationNotification, object: nil, userInfo: nil)
        return false
    }

    func release() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
    }
}

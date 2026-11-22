import Foundation

/// Reader-writer lock whose holders all run at the priority of the most urgent thread that
/// may wait for it.
///
/// `pthread_rwlock` does not lend the waiter's priority to the holder. A background thread
/// that is preempted inside the lock while the machine is busy would keep the main thread
/// waiting for as long as the scheduler leaves it off a core, which the user sees as a
/// terminal that stops answering the wheel and the keyboard while every other application
/// stays fluid. So every thread below user-interactive takes that priority for exactly as
/// long as it waits for and holds the lock: nothing less urgent than the main thread can
/// then stand between the main thread and the lock.
final class ReadWriteLock {
    private var rawLock = pthread_rwlock_t()

    @inline(__always)
    private func raiseToLockPriority() -> pthread_override_t? {
        guard qos_class_self().rawValue < QOS_CLASS_USER_INTERACTIVE.rawValue else { return nil }
        return pthread_override_qos_class_start_np(pthread_self(), QOS_CLASS_USER_INTERACTIVE, 0)
    }

    @inline(__always)
    private func restorePriority(_ override: pthread_override_t?) {
        guard let override else { return }
        let result = pthread_override_qos_class_end_np(override)
        precondition(result == 0, "pthread_override_qos_class_end_np failed: \(result)")
    }

    init() {
        let result = pthread_rwlock_init(&rawLock, nil)
        precondition(result == 0, "pthread_rwlock_init failed: \(result)")
    }

    deinit {
        let result = pthread_rwlock_destroy(&rawLock)
        precondition(result == 0, "pthread_rwlock_destroy failed: \(result)")
    }

    func withReadLock<T>(_ body: () throws -> T) rethrows -> T {
        let priority = raiseToLockPriority()
        let result = pthread_rwlock_rdlock(&rawLock)
        precondition(result == 0, "pthread_rwlock_rdlock failed: \(result)")
        defer {
            let unlockResult = pthread_rwlock_unlock(&rawLock)
            precondition(unlockResult == 0, "pthread_rwlock_unlock failed: \(unlockResult)")
            restorePriority(priority)
        }
        return try body()
    }

    func tryWithReadLock<T>(_ body: () throws -> T) rethrows -> T? {
        let priority = raiseToLockPriority()
        let result = pthread_rwlock_tryrdlock(&rawLock)
        if result == EBUSY {
            restorePriority(priority)
            return nil
        }
        precondition(result == 0, "pthread_rwlock_tryrdlock failed: \(result)")
        defer {
            let unlockResult = pthread_rwlock_unlock(&rawLock)
            precondition(unlockResult == 0, "pthread_rwlock_unlock failed: \(unlockResult)")
            restorePriority(priority)
        }
        return try body()
    }

    func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        let priority = raiseToLockPriority()
        let result = pthread_rwlock_wrlock(&rawLock)
        precondition(result == 0, "pthread_rwlock_wrlock failed: \(result)")
        defer {
            let unlockResult = pthread_rwlock_unlock(&rawLock)
            precondition(unlockResult == 0, "pthread_rwlock_unlock failed: \(unlockResult)")
            restorePriority(priority)
        }
        return try body()
    }
}

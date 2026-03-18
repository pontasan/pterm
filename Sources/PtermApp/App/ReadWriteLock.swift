import Foundation

final class ReadWriteLock {
    private var rawLock = pthread_rwlock_t()

    init() {
        let result = pthread_rwlock_init(&rawLock, nil)
        precondition(result == 0, "pthread_rwlock_init failed: \(result)")
    }

    deinit {
        let result = pthread_rwlock_destroy(&rawLock)
        precondition(result == 0, "pthread_rwlock_destroy failed: \(result)")
    }

    func withReadLock<T>(_ body: () throws -> T) rethrows -> T {
        let result = pthread_rwlock_rdlock(&rawLock)
        precondition(result == 0, "pthread_rwlock_rdlock failed: \(result)")
        defer {
            let unlockResult = pthread_rwlock_unlock(&rawLock)
            precondition(unlockResult == 0, "pthread_rwlock_unlock failed: \(unlockResult)")
        }
        return try body()
    }

    func tryWithReadLock<T>(_ body: () throws -> T) rethrows -> T? {
        let result = pthread_rwlock_tryrdlock(&rawLock)
        if result == EBUSY {
            return nil
        }
        precondition(result == 0, "pthread_rwlock_tryrdlock failed: \(result)")
        defer {
            let unlockResult = pthread_rwlock_unlock(&rawLock)
            precondition(unlockResult == 0, "pthread_rwlock_unlock failed: \(unlockResult)")
        }
        return try body()
    }

    func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        let result = pthread_rwlock_wrlock(&rawLock)
        precondition(result == 0, "pthread_rwlock_wrlock failed: \(result)")
        defer {
            let unlockResult = pthread_rwlock_unlock(&rawLock)
            precondition(unlockResult == 0, "pthread_rwlock_unlock failed: \(unlockResult)")
        }
        return try body()
    }
}

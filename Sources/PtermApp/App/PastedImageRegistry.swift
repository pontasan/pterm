import Foundation
import UniformTypeIdentifiers

final class PastedImageRegistry {
    private let fileManager: FileManager
    private var imageURLs: [URL] = []
    private let lock = NSLock()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func register(createdFiles: [URL]) {
        let imageFiles = createdFiles.filter(Self.isImageFileURL)
        guard !imageFiles.isEmpty else { return }
        lock.withLock {
            imageURLs.append(contentsOf: imageFiles)
        }
    }

    func url(forPlaceholderIndex index: Int) -> URL? {
        guard index > 0 else { return nil }
        return lock.withLock {
            guard index <= imageURLs.count else { return nil }
            let url = imageURLs[index - 1]
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    func registeredImageCount() -> Int {
        lock.withLock { imageURLs.count }
    }

    static func isImageFileURL(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty,
              let utType = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return utType.conforms(to: .image)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum TerminalImagePayloadFormat: Equatable {
    case png
    case jpeg
    case gif
    case webp
    case rawRGB
    case rawRGBA

    init?(kittyFormatCode: Int) {
        switch kittyFormatCode {
        case 24: self = .rawRGB
        case 32: self = .rawRGBA
        case 100: self = .png
        default: return nil
        }
    }

    var pathExtension: String {
        switch self {
        case .png, .rawRGB, .rawRGBA: return "png"
        case .jpeg: return "jpg"
        case .gif: return "gif"
        case .webp: return "webp"
        }
    }

    var blobPathExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .gif: return "gif"
        case .webp: return "webp"
        case .rawRGB: return "rgb"
        case .rawRGBA: return "rgba"
        }
    }
}

final class PastedImageRegistry {
    private static let fileBackedGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private struct ImageKey: Hashable {
        let ownerID: UUID?
        let index: Int
    }

    struct RegisteredImage: Equatable {
        let generation: UUID
        let url: URL?
        let blobURL: URL?
        let cgImage: CGImage?
        let rawPixelData: Data?
        let rawPixelFormat: TerminalImagePayloadFormat?
        let pixelWidth: Int?
        let pixelHeight: Int?
        let columns: Int?
        let rows: Int?

        static func == (lhs: RegisteredImage, rhs: RegisteredImage) -> Bool {
            lhs.generation == rhs.generation
                && lhs.url == rhs.url
                && lhs.blobURL == rhs.blobURL
                && lhs.columns == rhs.columns
                && lhs.rows == rhs.rows
                && lhs.cgImage === rhs.cgImage
        }
    }

    static let shared = PastedImageRegistry()

    private let fileManager: FileManager
    private var imageURLs: [URL] = []
    private var indexedImages: [ImageKey: RegisteredImage] = [:]
    private var invalidatedOwners: Set<UUID> = []
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
        url(ownerID: nil, forPlaceholderIndex: index)
    }

    func url(ownerID: UUID?, forPlaceholderIndex index: Int) -> URL? {
        guard index > 0 else { return nil }
        if let url = lock.withLock({ () -> URL? in
            if let explicit = indexedImages[ImageKey(ownerID: ownerID, index: index)] {
                guard let explicitURL = explicit.url else { return nil }
                guard fileManager.fileExists(atPath: explicitURL.path) else { return nil }
                return explicitURL
            }
            guard index <= imageURLs.count else { return nil }
            let url = imageURLs[index - 1]
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return url
        }) {
            return url
        }
        let hasLazyExplicitImage = lock.withLock {
            guard let explicit = indexedImages[ImageKey(ownerID: ownerID, index: index)] else { return false }
            return explicit.url == nil && (explicit.cgImage != nil || explicit.rawPixelData != nil || explicit.blobURL != nil)
        }
        if !hasLazyExplicitImage {
            return nil
        }
        return persistIndexedImageIfNeeded(ownerID: ownerID, index: index)
    }

    func registeredImageCount() -> Int {
        lock.withLock {
            imageURLs.count + indexedImages.count
        }
    }

    func register(url: URL, forPlaceholderIndex index: Int) {
        register(url: url, ownerID: nil, forPlaceholderIndex: index)
    }

    func register(url: URL, ownerID: UUID?, forPlaceholderIndex index: Int) {
        guard index > 0, Self.isImageFileURL(url) else { return }
        lock.withLock {
            indexedImages[ImageKey(ownerID: ownerID, index: index)] = RegisteredImage(
                generation: UUID(),
                url: url,
                blobURL: nil,
                cgImage: nil,
                rawPixelData: nil,
                rawPixelFormat: nil,
                pixelWidth: nil,
                pixelHeight: nil,
                columns: nil,
                rows: nil
            )
        }
    }

    func registeredImage(forPlaceholderIndex index: Int) -> RegisteredImage? {
        registeredImage(ownerID: nil, forPlaceholderIndex: index)
    }

    func registeredImage(ownerID: UUID?, forPlaceholderIndex index: Int) -> RegisteredImage? {
        guard index > 0 else { return nil }
        return lock.withLock {
            if let explicit = indexedImages[ImageKey(ownerID: ownerID, index: index)] {
                if let explicitURL = explicit.url {
                    guard fileManager.fileExists(atPath: explicitURL.path) else { return nil }
                }
                return explicit
            }
            guard index <= imageURLs.count else { return nil }
            let url = imageURLs[index - 1]
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return RegisteredImage(
                generation: Self.fileBackedGeneration,
                url: url,
                blobURL: nil,
                cgImage: nil,
                rawPixelData: nil,
                rawPixelFormat: nil,
                pixelWidth: nil,
                pixelHeight: nil,
                columns: nil,
                rows: nil
            )
        }
    }

    func registerTransient(
        imageData: Data,
        format: TerminalImagePayloadFormat,
        placeholderIndex index: Int,
        ownerID: UUID? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        columns: Int? = nil,
        rows: Int? = nil
    ) throws {
        guard index > 0 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if let ownerID,
           lock.withLock({ invalidatedOwners.contains(ownerID) }) {
            return
        }
        switch format {
        case .png, .jpeg, .gif, .webp:
            let destination = try persistTransientImageDataToFile(
                imageData,
                format: format,
                placeholderIndex: index
            )
            let previousURL = lock.withLock { () -> URL? in
                if let ownerID, invalidatedOwners.contains(ownerID) {
                    return nil
                }
                let key = ImageKey(ownerID: ownerID, index: index)
                let old = indexedImages[key]?.url
                indexedImages[key] = RegisteredImage(
                    generation: UUID(),
                    url: destination,
                    blobURL: nil,
                    cgImage: nil,
                    rawPixelData: nil,
                    rawPixelFormat: nil,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    columns: columns,
                    rows: rows
                )
                return old
            }

            if let previousURL,
               previousURL != destination,
               previousURL.deletingLastPathComponent().standardizedFileURL == PtermDirectories.files.standardizedFileURL {
                try? fileManager.removeItem(at: previousURL)
            }
            return
        case .rawRGB, .rawRGBA:
            guard let width = pixelWidth,
                  let height = pixelHeight,
                  width > 0,
                  height > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let blobURL = try persistTransientImageDataToFile(
                imageData,
                format: format,
                placeholderIndex: index
            )
            let previousURLs = lock.withLock { () -> (URL?, URL?) in
                if let ownerID, invalidatedOwners.contains(ownerID) {
                    return (nil, nil)
                }
                let key = ImageKey(ownerID: ownerID, index: index)
                let old = indexedImages[key]
                indexedImages[key] = RegisteredImage(
                    generation: UUID(),
                    url: nil,
                    blobURL: blobURL,
                    cgImage: nil,
                    rawPixelData: nil,
                    rawPixelFormat: format,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    columns: columns,
                    rows: rows
                )
                return (old?.url, old?.blobURL)
            }

            for candidate in [previousURLs.0, previousURLs.1].compactMap({ $0 })
            where candidate.deletingLastPathComponent().standardizedFileURL == PtermDirectories.files.standardizedFileURL {
                try? fileManager.removeItem(at: candidate)
            }
            return
        }
    }

    @discardableResult
    func register(
        imageData: Data,
        format: TerminalImagePayloadFormat,
        placeholderIndex index: Int,
        ownerID: UUID? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        columns: Int? = nil,
        rows: Int? = nil
    ) throws -> URL {
        guard index > 0 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let persistedData = try Self.persistableData(
            from: imageData,
            format: format,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )

        PtermDirectories.ensureDirectories()
        let destination = PtermDirectories.files.appendingPathComponent(
            "kitty-image-\(index)-\(UUID().uuidString).\(format.pathExtension)"
        )
        try AtomicFileWriter.write(persistedData, to: destination, permissions: 0o600)
        let cgImage = Self.cgImage(from: persistedData, format: .png, pixelWidth: pixelWidth, pixelHeight: pixelHeight)

        let previousURL = lock.withLock { () -> URL? in
            if let ownerID, invalidatedOwners.contains(ownerID) {
                return nil
            }
            let key = ImageKey(ownerID: ownerID, index: index)
            let old = indexedImages[key]?.url
            indexedImages[key] = RegisteredImage(
                generation: UUID(),
                url: destination,
                blobURL: nil,
                cgImage: cgImage,
                rawPixelData: nil,
                rawPixelFormat: nil,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                columns: columns,
                rows: rows
            )
            return old
        }

        if let previousURL,
           previousURL != destination,
           previousURL.deletingLastPathComponent().standardizedFileURL == PtermDirectories.files.standardizedFileURL {
            try? fileManager.removeItem(at: previousURL)
        }

        return destination
    }

    func reset() {
        lock.withLock {
            imageURLs.removeAll(keepingCapacity: false)
            indexedImages.removeAll(keepingCapacity: false)
            invalidatedOwners.removeAll(keepingCapacity: false)
        }
    }

    func removeImages(ownerID: UUID) {
        let urlsToDelete = lock.withLock { () -> [URL] in
            invalidatedOwners.insert(ownerID)
            let keysToRemove = indexedImages.keys.filter { $0.ownerID == ownerID }
            let urls = keysToRemove.flatMap { key -> [URL] in
                guard let image = indexedImages[key] else { return [] }
                return [image.url, image.blobURL].compactMap { $0 }
            }
            for key in keysToRemove {
                indexedImages.removeValue(forKey: key)
            }
            return urls
        }
        for url in urlsToDelete
        where url.deletingLastPathComponent().standardizedFileURL == PtermDirectories.files.standardizedFileURL {
            try? fileManager.removeItem(at: url)
        }
    }

    @discardableResult
    func purgeUnreferencedImages(ownerID: UUID, retainingPlaceholderIndices liveIndices: Set<Int>) -> [URL] {
        let urlsToDelete = lock.withLock { () -> [URL] in
            let keysToRemove = indexedImages.keys.filter { key in
                key.ownerID == ownerID && !liveIndices.contains(key.index)
            }
            let urls = keysToRemove.flatMap { key -> [URL] in
                guard let image = indexedImages[key] else { return [] }
                return [image.url, image.blobURL].compactMap { $0 }
            }
            for key in keysToRemove {
                indexedImages.removeValue(forKey: key)
            }
            return urls
        }
        for url in urlsToDelete
        where url.deletingLastPathComponent().standardizedFileURL == PtermDirectories.files.standardizedFileURL {
            try? fileManager.removeItem(at: url)
        }
        return urlsToDelete
    }

    static func isImageFileURL(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty,
              let utType = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return utType.conforms(to: .image)
    }

    private func persistIndexedImageIfNeeded(ownerID: UUID?, index: Int) -> URL? {
        let key = ImageKey(ownerID: ownerID, index: index)
        let snapshot = lock.withLock { indexedImages[key] }
        guard let snapshot,
              snapshot.url == nil else {
            return nil
        }

        let persistedData: Data?
        if let cgImage = snapshot.cgImage {
            persistedData = Self.pngData(from: cgImage)
        } else if let rawPixelData = snapshot.rawPixelData,
                  let rawPixelFormat = snapshot.rawPixelFormat {
            persistedData = try? Self.persistableData(
                from: rawPixelData,
                format: rawPixelFormat,
                pixelWidth: snapshot.pixelWidth,
                pixelHeight: snapshot.pixelHeight
            )
        } else if let blobData = Self.mappedBlobData(for: snapshot),
                  let rawPixelFormat = snapshot.rawPixelFormat {
            persistedData = try? Self.persistableData(
                from: blobData,
                format: rawPixelFormat,
                pixelWidth: snapshot.pixelWidth,
                pixelHeight: snapshot.pixelHeight
            )
        } else {
            persistedData = nil
        }
        guard let persistedData else { return nil }

        PtermDirectories.ensureDirectories()
        let destination = PtermDirectories.files.appendingPathComponent(
            "kitty-image-\(index)-\(UUID().uuidString).png"
        )
        do {
            try AtomicFileWriter.write(persistedData, to: destination, permissions: 0o600)
        } catch {
            return nil
        }

        lock.withLock {
            guard let current = indexedImages[key], current.url == nil else { return }
            indexedImages[key] = RegisteredImage(
                generation: current.generation,
                url: destination,
                blobURL: current.blobURL,
                cgImage: current.cgImage,
                rawPixelData: current.rawPixelData,
                rawPixelFormat: current.rawPixelFormat,
                pixelWidth: current.pixelWidth,
                pixelHeight: current.pixelHeight,
                columns: current.columns,
                rows: current.rows
            )
        }
        return destination
    }

    private func persistTransientImageDataToFile(
        _ imageData: Data,
        format: TerminalImagePayloadFormat,
        placeholderIndex index: Int
    ) throws -> URL {
        PtermDirectories.ensureDirectories()
        let destination = PtermDirectories.files.appendingPathComponent(
            "kitty-image-\(index)-\(UUID().uuidString).\(format.pathExtension)"
        )
        try AtomicFileWriter.write(imageData, to: destination, permissions: 0o600)
        return destination
    }

    private static func persistableData(
        from imageData: Data,
        format: TerminalImagePayloadFormat,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) throws -> Data {
        switch format {
        case .png, .jpeg, .gif, .webp:
            return imageData
        case .rawRGB, .rawRGBA:
            guard let cgImage = cgImage(
                from: imageData,
                format: format,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            ),
            let pngData = pngData(from: cgImage) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return pngData
        }
    }

    static func cgImage(
        from imageData: Data,
        format: TerminalImagePayloadFormat,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) -> CGImage? {
        switch format {
        case .png, .jpeg, .gif, .webp:
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        case .rawRGB, .rawRGBA:
            guard let width = pixelWidth, let height = pixelHeight else { return nil }
            return cgImageFromRawPixelData(imageData, format: format, width: width, height: height)
        }
    }

    static func cgImageFromRawPixelData(
        _ data: Data,
        format: TerminalImagePayloadFormat,
        width: Int,
        height: Int
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let samplesPerPixel: Int
        switch format {
        case .rawRGB:
            samplesPerPixel = 3
        case .rawRGBA:
            samplesPerPixel = 4
        default:
            return nil
        }

        let expectedLength = width * height * samplesPerPixel
        guard data.count == expectedLength else { return nil }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = samplesPerPixel == 4
            ? [.byteOrderDefault, CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)]
            : [.byteOrderDefault, CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)]
        let bitsPerComponent = 8
        let bitsPerPixel = samplesPerPixel * bitsPerComponent
        let bytesPerRow = width * samplesPerPixel

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func pngData(from cgImage: CGImage) -> Data? {
        let representation = NSBitmapImageRep(cgImage: cgImage)
        return representation.representation(using: .png, properties: [:])
    }

    static func mappedBlobData(for registeredImage: RegisteredImage) -> Data? {
        guard let blobURL = registeredImage.blobURL else { return nil }
        return try? Data(contentsOf: blobURL, options: .mappedIfSafe)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

import AppKit
import Foundation
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
}

final class PastedImageRegistry {
    struct RegisteredImage: Equatable {
        let url: URL
        let columns: Int?
        let rows: Int?
    }

    static let shared = PastedImageRegistry()

    private let fileManager: FileManager
    private var imageURLs: [URL] = []
    private var indexedImages: [Int: RegisteredImage] = [:]
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
            if let explicit = indexedImages[index] {
                let explicitURL = explicit.url
                guard fileManager.fileExists(atPath: explicitURL.path) else { return nil }
                return explicitURL
            }
            guard index <= imageURLs.count else { return nil }
            let url = imageURLs[index - 1]
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    func registeredImageCount() -> Int {
        lock.withLock {
            imageURLs.count + indexedImages.keys.filter { $0 > imageURLs.count }.count
        }
    }

    func register(url: URL, forPlaceholderIndex index: Int) {
        guard index > 0, Self.isImageFileURL(url) else { return }
        lock.withLock {
            indexedImages[index] = RegisteredImage(url: url, columns: nil, rows: nil)
        }
    }

    func registeredImage(forPlaceholderIndex index: Int) -> RegisteredImage? {
        guard index > 0 else { return nil }
        return lock.withLock {
            if let explicit = indexedImages[index] {
                guard fileManager.fileExists(atPath: explicit.url.path) else { return nil }
                return explicit
            }
            guard index <= imageURLs.count else { return nil }
            let url = imageURLs[index - 1]
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return RegisteredImage(url: url, columns: nil, rows: nil)
        }
    }

    @discardableResult
    func register(
        imageData: Data,
        format: TerminalImagePayloadFormat,
        placeholderIndex index: Int,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        columns: Int? = nil,
        rows: Int? = nil
    ) throws -> URL {
        guard index > 0 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let persistedData: Data
        switch format {
        case .png, .jpeg, .gif, .webp:
            persistedData = imageData
        case .rawRGB, .rawRGBA:
            guard let width = pixelWidth,
                  let height = pixelHeight,
                  let converted = Self.pngDataFromRawPixels(
                    imageData,
                    format: format,
                    width: width,
                    height: height
                  ) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            persistedData = converted
        }

        PtermDirectories.ensureDirectories()
        let destination = PtermDirectories.files.appendingPathComponent(
            "kitty-image-\(index)-\(UUID().uuidString).\(format.pathExtension)"
        )
        try AtomicFileWriter.write(persistedData, to: destination, permissions: 0o600)

        let previousURL = lock.withLock { () -> URL? in
            let old = indexedImages[index]?.url
            indexedImages[index] = RegisteredImage(url: destination, columns: columns, rows: rows)
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
        }
    }

    static func isImageFileURL(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty,
              let utType = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return utType.conforms(to: .image)
    }

    private static func pngDataFromRawPixels(
        _ data: Data,
        format: TerminalImagePayloadFormat,
        width: Int,
        height: Int
    ) -> Data? {
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

        guard let image = CGImage(
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
        ) else {
            return nil
        }

        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .png, properties: [:])
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

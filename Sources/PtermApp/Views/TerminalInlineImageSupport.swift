import AppKit
import Foundation

struct TerminalInlineImagePlacement: Equatable {
    let ownerID: UUID?
    let index: Int
    let row: Int
    let startCol: Int
    let endCol: Int
    let rowSpan: Int
    let originalText: String
}

enum TerminalInlineImageSupport {
    private static let imageCache = NSCache<NSURL, NSImage>()

    static func evictCachedImages(for urls: some Sequence<URL>) {
        for url in urls {
            imageCache.removeObject(forKey: url as NSURL)
        }
    }

    static func detectPlacements(in snapshot: TerminalController.RenderSnapshot) -> [TerminalInlineImagePlacement] {
        snapshot.inlineImagePlacements
    }

    static func detectPlacements(in rows: [TerminalController.RenderRowSnapshot], ownerID: UUID? = nil) -> [TerminalInlineImagePlacement] {
        var placements: [TerminalInlineImagePlacement] = []
        placements.reserveCapacity(4)
        var seenAnchors = Set<String>()
        for (rowIndex, row) in rows.enumerated() {
            for (colIndex, cell) in row.cells.enumerated() {
                guard cell.hasInlineImage else {
                    continue
                }
                let anchorRow = rowIndex - Int(cell.imageOriginRowOffset)
                let anchorCol = colIndex - Int(cell.imageOriginColOffset)
                let anchorKey = "\(cell.imageID):\(anchorRow):\(anchorCol)"
                guard seenAnchors.insert(anchorKey).inserted else { continue }
                let columnSpan = max(Int(cell.imageColumns), 1)
                let rowSpan = max(Int(cell.imageRows), 1)
                placements.append(
                    TerminalInlineImagePlacement(
                        ownerID: ownerID,
                        index: Int(cell.imageID),
                        row: anchorRow,
                        startCol: anchorCol,
                        endCol: anchorCol + columnSpan - 1,
                        rowSpan: rowSpan,
                        originalText: "[Image #\(cell.imageID)]"
                    )
                )
            }
        }
        return placements
    }

    static func hiddenPlaceholderColumns(in rows: [TerminalController.RenderRowSnapshot]) -> [IndexSet] {
        Array(
            rows.map { row in
                var hidden = IndexSet()
                for (colIndex, cell) in row.cells.enumerated() where cell.hasInlineImage {
                    hidden.insert(colIndex)
                }
                return hidden
            }
        )
    }

    static func cgImage(for registeredImage: PastedImageRegistry.RegisteredImage) -> CGImage? {
        if let cgImage = registeredImage.cgImage {
            return cgImage
        }
        if let blobData = PastedImageRegistry.mappedBlobData(for: registeredImage),
           let rawPixelFormat = registeredImage.rawPixelFormat,
           let cgImage = PastedImageRegistry.cgImage(
                from: blobData,
                format: rawPixelFormat,
                pixelWidth: registeredImage.pixelWidth,
                pixelHeight: registeredImage.pixelHeight
           ) {
            return cgImage
        }
        if let rawPixelData = registeredImage.rawPixelData,
           let rawPixelFormat = registeredImage.rawPixelFormat,
           let cgImage = PastedImageRegistry.cgImage(
                from: rawPixelData,
                format: rawPixelFormat,
                pixelWidth: registeredImage.pixelWidth,
                pixelHeight: registeredImage.pixelHeight
           ) {
            return cgImage
        }
        if let rawPixelData = registeredImage.rawPixelData,
           let rawPixelFormat = registeredImage.rawPixelFormat,
           let pixelWidth = registeredImage.pixelWidth,
           let pixelHeight = registeredImage.pixelHeight {
            return PastedImageRegistry.cgImageFromRawPixelData(
                rawPixelData,
                format: rawPixelFormat,
                width: pixelWidth,
                height: pixelHeight
            )
        }
        guard let url = registeredImage.url,
              let image = image(for: url) else {
            return nil
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func image(for url: URL) -> NSImage? {
        let key = url as NSURL
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    static func frame(
        for placement: TerminalInlineImagePlacement,
        registeredImage: PastedImageRegistry.RegisteredImage?,
        gridPadding: CGFloat,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        viewHeight: CGFloat,
        offsetX: CGFloat = 0,
        offsetY: CGFloat = 0
    ) -> CGRect {
        let columnSpan = max(registeredImage?.columns ?? (placement.endCol - placement.startCol + 1), 1)
        let rowSpan = max(registeredImage?.rows ?? placement.rowSpan, 1)
        return CGRect(
            x: offsetX + gridPadding + CGFloat(placement.startCol) * cellWidth,
            y: offsetY + viewHeight - gridPadding - CGFloat(placement.row + rowSpan) * cellHeight,
            width: CGFloat(columnSpan) * cellWidth,
            height: CGFloat(rowSpan) * cellHeight
        ).integral
    }
}

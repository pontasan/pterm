import AppKit
import Foundation

struct TerminalInlineImagePlacement: Equatable {
    let index: Int
    let row: Int
    let startCol: Int
    let endCol: Int
    let rowSpan: Int
    let originalText: String
}

enum TerminalInlineImageSupport {
    private static let imageCache = NSCache<NSURL, NSImage>()

    static func detectPlacements(in snapshot: TerminalController.RenderSnapshot) -> [TerminalInlineImagePlacement] {
        detectPlacements(in: snapshot.visibleRows)
    }

    static func detectPlacements(in rows: [TerminalController.RenderRowSnapshot]) -> [TerminalInlineImagePlacement] {
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

    static func image(for url: URL) -> NSImage? {
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

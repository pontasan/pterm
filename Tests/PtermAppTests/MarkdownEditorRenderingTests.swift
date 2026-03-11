import AppKit
import XCTest
@testable import PtermApp

@MainActor
final class MarkdownEditorRenderingTests: XCTestCase {
    func testEditorRendersVisibleGlyphsForNonEmptyText() throws {
        let outputDirectory = URL(fileURLWithPath: "/Users/umedatomohiro/Developments/workspace/pterm-ai/.tmp/test-note-editor",
                                  isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let controller = MarkdownEditorWindowController(
            workspaceName: "Test",
            initialText: "",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        let beforeBitmap = try bitmap(in: textView)
        try write(bitmap: beforeBitmap, to: outputDirectory.appendingPathComponent("before.png"))

        textView.insertText("abc\n日本語", replacementRange: textView.selectedRange())
        textView.displayIfNeeded()

        XCTAssertEqual(textView.string, "abc\n日本語")
        if let color = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
           let rgb = color.usingColorSpace(.deviceRGB) {
            XCTAssertGreaterThan(rgb.redComponent, 0.5, "Expected visible foreground color for inserted text")
            XCTAssertGreaterThan(rgb.greenComponent, 0.5, "Expected visible foreground color for inserted text")
            XCTAssertGreaterThan(rgb.blueComponent, 0.5, "Expected visible foreground color for inserted text")
        } else {
            XCTFail("Inserted text did not have a foreground color attribute")
        }

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            XCTFail("Markdown editor text system was not configured")
            return
        }

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        XCTAssertGreaterThan(glyphRange.length, 0, "Expected glyphs for non-empty text")

        let usedRect = layoutManager.usedRect(for: textContainer)
        XCTAssertGreaterThan(usedRect.width, 0, "Expected non-zero layout width")
        XCTAssertGreaterThan(usedRect.height, 0, "Expected non-zero layout height")

        let afterBitmap = try bitmap(in: textView)
        try write(bitmap: afterBitmap, to: outputDirectory.appendingPathComponent("after.png"))
        let contentStartX = Int(ceil(textView.textContainerInset.width)) + 8
        let changedPixels = changedPixelCount(before: beforeBitmap, after: afterBitmap, contentStartX: contentStartX)
        let brightPixels = brightPixelCount(in: afterBitmap, contentStartX: contentStartX)
        try """
        string=\(textView.string.debugDescription)
        contentStartX=\(contentStartX)
        changedPixels=\(changedPixels)
        brightPixels=\(brightPixels)
        textColor=\(String(describing: textView.textColor))
        typingAttributes=\(textView.typingAttributes)
        """.write(to: outputDirectory.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)

        XCTAssertGreaterThan(
            changedPixels,
            500,
            "Expected inserting text to visibly change the editor content bitmap"
        )
        XCTAssertGreaterThan(
            brightPixels,
            500,
            "Expected bright text pixels in the editor content region"
        )
    }

    func testEditorAutoFormatsMarkdownListContinuation() throws {
        let controller = MarkdownEditorWindowController(
            workspaceName: "Test",
            initialText: "- item",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "- item\n- ")
    }

    func testEditorUsesFindBarAndSupportsCopyPasteSelectors() throws {
        let controller = MarkdownEditorWindowController(
            workspaceName: "Test",
            initialText: "abc",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        XCTAssertTrue(textView.usesFindBar)
        XCTAssertTrue(textView.responds(to: #selector(NSText.copy(_:))))
        XCTAssertTrue(textView.responds(to: #selector(NSText.paste(_:))))
        XCTAssertTrue(textView.responds(to: #selector(NSText.cut(_:))))
    }

    private func requireWindow(from controller: NSWindowController) throws -> NSWindow {
        guard let window = controller.window else {
            throw NSError(domain: "MarkdownEditorRenderingTests", code: 1)
        }
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func findTextView(in window: NSWindow) -> NSTextView? {
        guard let contentView = window.contentView else { return nil }
        return findTextView(in: contentView)
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }
        return nil
    }

    private func bitmap(in textView: NSTextView) throws -> NSBitmapImageRep {
        textView.displayIfNeeded()
        let bounds = textView.bounds.integral
        guard let bitmap = textView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw NSError(domain: "MarkdownEditorRenderingTests", code: 2)
        }

        bitmap.size = bounds.size
        textView.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }

    private func changedPixelCount(before: NSBitmapImageRep, after: NSBitmapImageRep, contentStartX: Int) -> Int {
        precondition(before.pixelsWide == after.pixelsWide && before.pixelsHigh == after.pixelsHigh)
        var count = 0
        for y in 0..<before.pixelsHigh {
            for x in max(contentStartX, 0)..<before.pixelsWide {
                guard let beforeColor = before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let afterColor = after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let delta =
                    abs(beforeColor.redComponent - afterColor.redComponent) +
                    abs(beforeColor.greenComponent - afterColor.greenComponent) +
                    abs(beforeColor.blueComponent - afterColor.blueComponent) +
                    abs(beforeColor.alphaComponent - afterColor.alphaComponent)
                if delta > 0.05 {
                    count += 1
                }
            }
        }
        return count
    }

    private func brightPixelCount(in bitmap: NSBitmapImageRep, contentStartX: Int) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in max(contentStartX, 0)..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.redComponent > 0.55 || color.greenComponent > 0.55 || color.blueComponent > 0.55 {
                    count += 1
                }
            }
        }
        return count
    }

    private func write(bitmap: NSBitmapImageRep, to url: URL) throws {
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "MarkdownEditorRenderingTests", code: 3)
        }
        try data.write(to: url, options: .atomic)
    }
}

import AppKit
import XCTest
@testable import PtermApp

@MainActor
final class MarkdownEditorRenderingTests: XCTestCase {
    func testEditorRendersVisibleGlyphsForNonEmptyText() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pterm-test-note-editor", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let controller = MarkdownEditorWindowController(
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
        var effectiveRange = NSRange(location: 0, length: 0)
        if let color = textView.textStorage?.attribute(NSAttributedString.Key.foregroundColor, at: 0, effectiveRange: &effectiveRange) as? NSColor,
           let rgb = color.usingColorSpace(NSColorSpace.deviceRGB) {
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
            200,
            "Expected inserting text to visibly change the editor content bitmap"
        )
        XCTAssertGreaterThan(
            brightPixels,
            200,
            "Expected bright text pixels in the editor content region"
        )
    }

    func testEditorAutoFormatsMarkdownListContinuation() throws {
        let controller = MarkdownEditorWindowController(
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

    func testEditorAutoFormatsAsteriskListContinuation() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "* item",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "* item\n* ")
    }

    func testEditorAutoFormatsPlusListContinuation() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "+ item",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "+ item\n+ ")
    }

    func testEditorAutoFormatsOrderedListContinuation() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "9. item",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "9. item\n10. ")
    }

    func testEditorAutoFormatsIndentedOrderedListContinuation() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "  7. item",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "  7. item\n  8. ")
    }

    func testEditorAutoFormatsTaskListContinuation() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "- [x] done",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "- [x] done\n- [ ] ")
    }

    func testEditorAutoFormatsTaskListContinuationWithPlusMarkerAndUppercaseX() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "+ [X] done",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "+ [X] done\n+ [ ] ")
    }

    func testEditorAutoFormatsTaskListContinuationWithPlusMarker() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "+ [x] done",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "+ [x] done\n+ [ ] ")
    }

    func testEditorAutoFormatsTaskListContinuationWithAsteriskMarker() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "* [x] done",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "* [x] done\n* [ ] ")
    }

    func testEditorAutoFormatsTaskListContinuationWithAsteriskMarkerAndUppercaseX() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "* [X] done",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "* [X] done\n* [ ] ")
    }

    func testEditorTaskListContinuationExitsOnEmptyMarkerLine() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "- [ ] ",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "\n")
    }

    func testEditorTaskListContinuationExitsOnCheckedMarkerLine() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "- [x] ",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "\n")
    }

    func testEditorTaskListContinuationExitsOnUppercaseCheckedMarkerLine() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "* [X] ",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "\n")
    }

    func testEditorTaskListContinuationExitsOnPlusMarkerLine() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "+ [ ] ",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "\n")
    }

    func testEditorTaskListContinuationExitsOnCheckedPlusMarkerLine() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "+ [x] ",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "\n")
    }

    func testEditorAutoFormatsBlockquoteContinuation() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "> quoted",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "> quoted\n> ")
    }

    func testEditorAutoFormatsNestedBlockquoteContinuation() throws {
        let controller = MarkdownEditorWindowController(
            initialText: ">> quoted",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, ">> quoted\n>> ")
    }

    func testEditorBlockquoteContinuationExitsOnEmptyMarkerLine() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "> ",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "\n")
    }

    func testEditorAutoFormatsIndentedMarkdownListContinuation() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "  - item",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "  - item\n  - ")
    }

    func testEditorListContinuationExitsOnEmptyMarkerLine() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "- ",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "\n")
    }

    func testEditorAsteriskListContinuationExitsOnEmptyMarkerLine() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "* ",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "\n")
    }

    func testEditorPlusListContinuationExitsOnEmptyMarkerLine() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "+ ",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "\n")
    }

    func testEditorOrderedListContinuationExitsOnEmptyMarkerLine() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "3. ",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(textView.string, "\n")
    }

    func testEditorInsertTabInsertsFourSpaces() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        _ = textView.delegate?.textView?(textView, doCommandBy: #selector(NSResponder.insertTab(_:)))

        XCTAssertEqual(textView.string, "    ")
    }

    func testEditorUsesFindBarAndSupportsCopyPasteSelectors() throws {
        let controller = MarkdownEditorWindowController(
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

    func testEditorHighlightsHeadingAndInlineCode() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "# Title\nUse `code`",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)),
              let storage = textView.textStorage else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        drainMainQueue(testCase: self)

        let headingColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let codeRange = (storage.string as NSString).range(of: "`code`")
        let codeBackground = storage.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor

        XCTAssertNotNil(headingColor)
        XCTAssertNotNil(codeBackground)
        XCTAssertNotEqual(
            headingColor?.usingColorSpace(.deviceRGB),
            MarkdownHighlighter.defaultColor.usingColorSpace(.deviceRGB)
        )
    }

    func testEditorHighlightsBoldItalicAndLinkText() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "**bold** _italic_ [link](https://example.com)",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)),
              let storage = textView.textStorage else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        drainMainQueue(testCase: self)

        let nsString = storage.string as NSString
        let boldRange = nsString.range(of: "**bold**")
        let italicRange = nsString.range(of: "_italic_")
        let linkRange = nsString.range(of: "[link](https://example.com)")

        let boldColor = storage.attribute(.foregroundColor, at: boldRange.location, effectiveRange: nil) as? NSColor
        let italicColor = storage.attribute(.foregroundColor, at: italicRange.location, effectiveRange: nil) as? NSColor
        let linkColor = storage.attribute(.foregroundColor, at: linkRange.location, effectiveRange: nil) as? NSColor

        XCTAssertNotNil(boldColor)
        XCTAssertNotNil(italicColor)
        XCTAssertNotNil(linkColor)
        XCTAssertNotEqual(
            boldColor?.usingColorSpace(.deviceRGB),
            MarkdownHighlighter.defaultColor.usingColorSpace(.deviceRGB)
        )
        XCTAssertNotEqual(
            italicColor?.usingColorSpace(.deviceRGB),
            MarkdownHighlighter.defaultColor.usingColorSpace(.deviceRGB)
        )
        XCTAssertNotEqual(
            linkColor?.usingColorSpace(.deviceRGB),
            MarkdownHighlighter.defaultColor.usingColorSpace(.deviceRGB)
        )
    }

    func testEditorHighlightsImageLinkAndHorizontalRule() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "![alt](https://example.com/image.png)\n---",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)),
              let storage = textView.textStorage else {
            XCTFail("Markdown editor text storage missing")
            return
        }

        drainMainQueue(testCase: self)

        let imageColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let hrRange = (storage.string as NSString).range(of: "---")
        let hrColor = storage.attribute(.foregroundColor, at: hrRange.location, effectiveRange: nil) as? NSColor

        XCTAssertNotEqual(
            imageColor?.usingColorSpace(.deviceRGB),
            MarkdownHighlighter.defaultColor.usingColorSpace(.deviceRGB)
        )
        XCTAssertNotEqual(
            hrColor?.usingColorSpace(.deviceRGB),
            MarkdownHighlighter.defaultColor.usingColorSpace(.deviceRGB)
        )
    }

    func testEditorHighlightsHorizontalRuleDifferentlyFromPlainParagraph() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "plain\n---",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)),
              let storage = textView.textStorage else {
            XCTFail("Markdown editor text storage missing")
            return
        }

        drainMainQueue(testCase: self)

        let nsString = storage.string as NSString
        let plainColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let hrRange = nsString.range(of: "---")
        let hrColor = storage.attribute(.foregroundColor, at: hrRange.location, effectiveRange: nil) as? NSColor

        XCTAssertNotEqual(
            hrColor?.usingColorSpace(.deviceRGB),
            plainColor?.usingColorSpace(.deviceRGB)
        )
    }

    func testEditorHighlightsFencedCodeBlockBackground() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "```swift\nlet value = 1\n```",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)),
              let storage = textView.textStorage else {
            XCTFail("Markdown editor text storage missing")
            return
        }

        drainMainQueue(testCase: self)

        let codeRange = (storage.string as NSString).range(of: "let value = 1")
        let background = storage.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor

        XCTAssertNotNil(background)
        XCTAssertNotEqual(
            background?.usingColorSpace(.deviceRGB),
            NSColor.clear.usingColorSpace(.deviceRGB)
        )
    }

    func testEditorHighlightsTaskListMarkerDifferentlyFromBodyText() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "- [x] done",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)),
              let storage = textView.textStorage else {
            XCTFail("Markdown editor text storage missing")
            return
        }

        drainMainQueue(testCase: self)

        let nsString = storage.string as NSString
        let markerRange = nsString.range(of: "- [x]")
        let bodyRange = nsString.range(of: "done")
        let markerColor = storage.attribute(.foregroundColor, at: markerRange.location, effectiveRange: nil) as? NSColor
        let bodyColor = storage.attribute(.foregroundColor, at: bodyRange.location, effectiveRange: nil) as? NSColor

        XCTAssertNotEqual(
            markerColor?.usingColorSpace(.deviceRGB),
            bodyColor?.usingColorSpace(.deviceRGB)
        )
    }

    func testEditorHighlightsOrderedListMarkerDifferentlyFromBodyText() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "12. item",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)),
              let storage = textView.textStorage else {
            XCTFail("Markdown editor text storage missing")
            return
        }

        drainMainQueue(testCase: self)

        let nsString = storage.string as NSString
        let markerRange = nsString.range(of: "12.")
        let bodyRange = nsString.range(of: "item")
        let markerColor = storage.attribute(.foregroundColor, at: markerRange.location, effectiveRange: nil) as? NSColor
        let bodyColor = storage.attribute(.foregroundColor, at: bodyRange.location, effectiveRange: nil) as? NSColor

        XCTAssertNotEqual(
            markerColor?.usingColorSpace(.deviceRGB),
            bodyColor?.usingColorSpace(.deviceRGB)
        )
    }

    func testEditorHighlightsUnorderedListMarkerDifferentlyFromBodyText() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "* item",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)),
              let storage = textView.textStorage else {
            XCTFail("Markdown editor text storage missing")
            return
        }

        drainMainQueue(testCase: self)

        let nsString = storage.string as NSString
        let markerRange = nsString.range(of: "*")
        let bodyRange = nsString.range(of: "item")
        let markerColor = storage.attribute(.foregroundColor, at: markerRange.location, effectiveRange: nil) as? NSColor
        let bodyColor = storage.attribute(.foregroundColor, at: bodyRange.location, effectiveRange: nil) as? NSColor

        XCTAssertNotEqual(
            markerColor?.usingColorSpace(.deviceRGB),
            bodyColor?.usingColorSpace(.deviceRGB)
        )
    }

    func testEditorHighlightsPlusListMarkerDifferentlyFromBodyText() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "+ item",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)),
              let storage = textView.textStorage else {
            XCTFail("Markdown editor text storage missing")
            return
        }

        drainMainQueue(testCase: self)

        let nsString = storage.string as NSString
        let markerRange = nsString.range(of: "+")
        let bodyRange = nsString.range(of: "item")
        let markerColor = storage.attribute(.foregroundColor, at: markerRange.location, effectiveRange: nil) as? NSColor
        let bodyColor = storage.attribute(.foregroundColor, at: bodyRange.location, effectiveRange: nil) as? NSColor

        XCTAssertNotEqual(
            markerColor?.usingColorSpace(.deviceRGB),
            bodyColor?.usingColorSpace(.deviceRGB)
        )
    }

    func testEditorHighlightsBlockquoteDifferentlyFromBodyText() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "> quoted",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)),
              let storage = textView.textStorage else {
            XCTFail("Markdown editor text storage missing")
            return
        }

        drainMainQueue(testCase: self)

        let markerColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor

        XCTAssertNotEqual(
            markerColor?.usingColorSpace(.deviceRGB),
            MarkdownHighlighter.defaultColor.usingColorSpace(.deviceRGB)
        )
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

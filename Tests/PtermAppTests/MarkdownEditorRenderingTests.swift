import AppKit
import MetalKit
import XCTest
@testable import PtermApp

@MainActor
final class MarkdownEditorRenderingTests: XCTestCase {
    private final class KeyClickSpy: TypewriterKeyClicking {
        private(set) var count = 0

        func playKeystroke() {
            count += 1
        }
    }

    func testEditorRendersVisibleGlyphsForNonEmptyText() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "",
            onSave: { _ in }
        )

        let window = try requireWindow(from: controller)
        guard let textView = findTextView(in: window) else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }
        guard let metalView = findMetalView(in: window) else {
            XCTFail("Markdown editor did not contain a Metal text surface")
            return
        }

        textView.insertText("abc\n日本語", replacementRange: textView.selectedRange())

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
        XCTAssertTrue(metalView.isPaused, "Markdown Metal surface should render on demand")
        XCTAssertTrue(metalView.enableSetNeedsDisplay, "Markdown Metal surface should be demand-driven")
        XCTAssertGreaterThan(metalView.drawableSize.width, 0, "Expected non-zero drawable width")
        XCTAssertGreaterThan(metalView.drawableSize.height, 0, "Expected non-zero drawable height")
        if let metalSurface = metalView as? MarkdownMetalSurfaceView {
            XCTAssertEqual(metalSurface.debugPrepareVisibleGlyphsForTesting(), 0, "Expected committed glyphs to stay masked while insert preview is active")
            XCTAssertGreaterThan(metalSurface.debugLastRenderedCharacterRange.length, 0, "Expected visible markdown characters to be rendered")
            XCTAssertGreaterThan(metalSurface.debugActivePreviewCount, 0, "Expected committed insert preview to be active")
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            XCTAssertEqual(metalSurface.debugActivePreviewCount, 0, "Expected committed insert preview to expire")
            XCTAssertGreaterThan(metalSurface.debugPrepareVisibleGlyphsForTesting(), 0, "Expected visible glyph vertices to be generated after preview finishes")
        } else {
            XCTFail("Markdown editor did not expose a markdown metal surface view")
        }
    }

    func testEditorMetalSurfaceCullsRenderingToVisibleRangeForLargeDocument() throws {
        let longText = (0..<2000).map { "line-\($0)" }.joined(separator: "\n")
        let controller = MarkdownEditorWindowController(
            initialText: longText,
            onSave: { _ in }
        )

        let window = try requireWindow(from: controller)
        guard let textView = findTextView(in: window),
              let metalView = findMarkdownMetalSurface(in: window) else {
            XCTFail("Markdown editor did not expose expected views")
            return
        }

        let renderedRange = metalView.debugCurrentCulledCharacterRange()
        XCTAssertGreaterThan(renderedRange.length, 0)
        XCTAssertLessThan(renderedRange.length, (textView.string as NSString).length)
    }

    func testEditorMetalSurfaceUpdatesCullRangeAfterScroll() throws {
        let longText = (0..<2000).map { "line-\($0)" }.joined(separator: "\n")
        let controller = MarkdownEditorWindowController(
            initialText: longText,
            onSave: { _ in }
        )

        let window = try requireWindow(from: controller)
        guard let textView = findTextView(in: window),
              let metalView = findMarkdownMetalSurface(in: window),
              let scrollView = textView.enclosingScrollView else {
            XCTFail("Markdown editor did not expose expected views")
            return
        }

        let before = metalView.debugCurrentCulledCharacterRange()

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 4000))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        let after = metalView.debugCurrentCulledCharacterRange()
        XCTAssertNotEqual(before.location, after.location)
    }

    func testEditorDeleteBackwardPlaysTypewriterSound() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "abc",
            onSave: { _ in }
        )

        let window = try requireWindow(from: controller)
        guard let textView = findTextView(in: window) as? MarkdownInputTextView else {
            XCTFail("Markdown editor did not contain a markdown input text view")
            return
        }

        let spy = KeyClickSpy()
        textView.inputFeedbackPlayer = spy
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        XCTAssertEqual(textView.string, "ab")
        XCTAssertEqual(spy.count, 1)
    }

    func testEditorDeleteBackwardCreatesTransientPreview() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "abc",
            onSave: { _ in }
        )

        let window = try requireWindow(from: controller)
        guard let textView = findTextView(in: window) as? MarkdownInputTextView,
              let metalSurface = findMarkdownMetalSurface(in: window) else {
            XCTFail("Markdown editor did not expose expected views")
            return
        }

        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertEqual(textView.string, "ab")
        XCTAssertGreaterThan(metalSurface.debugActivePreviewCount, 0, "Expected delete preview to be active")
    }

    func testEditorJapaneseMarkedTextOverlayMatchesCommittedRendererForRepeatedWideGlyphs() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "",
            onSave: { _ in }
        )

        let window = try requireWindow(from: controller)
        guard let textView = findTextView(in: window) as? MarkdownInputTextView,
              let metalSurface = findMarkdownMetalSurface(in: window) else {
            XCTFail("Markdown editor did not expose expected views")
            return
        }

        textView.setMarkedText("ああ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        metalSurface.debugUpdateMarkedTextOverlayNow()

        let overlayFrames = metalSurface.debugMarkedTextOverlayFramesForTesting

        textView.insertText("ああ", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        _ = metalSurface.debugPrepareVisibleGlyphsForTesting()
        let committedFrames = metalSurface.debugCommittedGlyphFramesForTesting()

        XCTAssertEqual(overlayFrames.count, 2)
        XCTAssertEqual(committedFrames.count, 2)
        XCTAssertEqual(overlayFrames[0].minX, committedFrames[0].minX, accuracy: 1.0)
        XCTAssertEqual(overlayFrames[1].minX, committedFrames[1].minX, accuracy: 1.0)
        XCTAssertEqual(overlayFrames[1].minX - overlayFrames[0].minX, committedFrames[1].minX - committedFrames[0].minX, accuracy: 1.0)
        XCTAssertEqual(overlayFrames[0].width, committedFrames[0].width, accuracy: 1.0)
        XCTAssertEqual(overlayFrames[1].width, committedFrames[1].width, accuracy: 1.0)
        XCTAssertEqual(overlayFrames[0].minY, committedFrames[0].minY, accuracy: 1.0)
        XCTAssertEqual(overlayFrames[1].minY, committedFrames[1].minY, accuracy: 1.0)
        XCTAssertEqual(
            overlayFrames[1].maxX - overlayFrames[0].minX,
            committedFrames[1].maxX - committedFrames[0].minX,
            accuracy: 1.0
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

    func testEditorHeadingUsesMonospacedBoldFontInsteadOfVariableWidthSystemBold() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "# test",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)),
              let storage = textView.textStorage else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        drainMainQueue(testCase: self)

        let headingFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(headingFont)
        XCTAssertTrue(headingFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        XCTAssertTrue(headingFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    func testEditorSyntaxHighlightFontsPreserveMonospaceAcrossStyledMarkdown() throws {
        let controller = MarkdownEditorWindowController(
            initialText: "# Heading\n**bold** _italic_ `code`\n```\nblock\n```",
            onSave: { _ in }
        )

        guard let textView = findTextView(in: try requireWindow(from: controller)),
              let storage = textView.textStorage else {
            XCTFail("Markdown editor did not contain an NSTextView")
            return
        }

        drainMainQueue(testCase: self)

        let nsString = storage.string as NSString
        let headingFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let boldFont = storage.attribute(.font, at: nsString.range(of: "bold").location, effectiveRange: nil) as? NSFont
        let italicFont = storage.attribute(.font, at: nsString.range(of: "italic").location, effectiveRange: nil) as? NSFont
        let inlineCodeFont = storage.attribute(.font, at: nsString.range(of: "code").location, effectiveRange: nil) as? NSFont
        let fencedCodeFont = storage.attribute(.font, at: nsString.range(of: "block").location, effectiveRange: nil) as? NSFont

        XCTAssertNotNil(headingFont)
        XCTAssertTrue(headingFont?.isFixedPitch == true, "Heading font should remain fixed-pitch")
        XCTAssertNotNil(boldFont)
        XCTAssertTrue(boldFont?.isFixedPitch == true, "Bold font should remain fixed-pitch")
        XCTAssertNotNil(italicFont)
        XCTAssertTrue(italicFont?.isFixedPitch == true, "Italic font should remain fixed-pitch")
        XCTAssertNotNil(inlineCodeFont)
        XCTAssertTrue(inlineCodeFont?.isFixedPitch == true, "Inline code font should remain fixed-pitch")
        XCTAssertNotNil(fencedCodeFont)
        XCTAssertTrue(fencedCodeFont?.isFixedPitch == true, "Fenced code font should remain fixed-pitch")
        XCTAssertTrue(headingFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertTrue(italicFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)
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

    private func findMetalView(in window: NSWindow) -> MTKView? {
        guard let contentView = window.contentView else { return nil }
        return findMetalView(in: contentView)
    }

    private func findMarkdownMetalSurface(in window: NSWindow) -> MarkdownMetalSurfaceView? {
        guard let contentView = window.contentView else { return nil }
        return findMarkdownMetalSurface(in: contentView)
    }

    private func findMarkdownMetalSurface(in view: NSView) -> MarkdownMetalSurfaceView? {
        if let surface = view as? MarkdownMetalSurfaceView {
            return surface
        }
        for subview in view.subviews {
            if let surface = findMarkdownMetalSurface(in: subview) {
                return surface
            }
        }
        return nil
    }

    private func findMetalView(in view: NSView) -> MTKView? {
        if let metalView = view as? MTKView {
            return metalView
        }
        for subview in view.subviews {
            if let metalView = findMetalView(in: subview) {
                return metalView
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

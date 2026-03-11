import AppKit

// MARK: - Markdown Syntax Highlighter

/// Applies Markdown syntax highlighting to an NSTextView's text storage.
/// Called explicitly after edits rather than via NSTextStorageDelegate to avoid
/// re-entrant attribute conflicts that can break text rendering.
final class MarkdownHighlighter {
    private let headingColor = NSColor(calibratedRed: 0.47, green: 0.65, blue: 0.93, alpha: 1)
    private let boldColor = NSColor(calibratedRed: 0.87, green: 0.78, blue: 0.56, alpha: 1)
    private let italicColor = NSColor(calibratedRed: 0.78, green: 0.67, blue: 0.86, alpha: 1)
    private let codeColor = NSColor(calibratedRed: 0.80, green: 0.56, blue: 0.47, alpha: 1)
    private let codeBgColor = NSColor(calibratedWhite: 0.15, alpha: 1)
    private let linkColor = NSColor(calibratedRed: 0.40, green: 0.73, blue: 0.72, alpha: 1)
    private let listMarkerColor = NSColor(calibratedRed: 0.87, green: 0.56, blue: 0.40, alpha: 1)
    private let blockquoteColor = NSColor(calibratedRed: 0.55, green: 0.63, blue: 0.55, alpha: 1)
    private let hrColor = NSColor(calibratedWhite: 0.45, alpha: 1)
    static let defaultColor = NSColor(calibratedWhite: 0.85, alpha: 1)

    let font: NSFont

    init(font: NSFont) {
        self.font = font
    }

    /// Apply full Markdown highlighting to the given text storage.
    /// Must be called on the main thread, outside of any processEditing cycle.
    func highlight(_ textStorage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }

        textStorage.beginEditing()

        textStorage.addAttributes([
            .foregroundColor: Self.defaultColor,
            .font: font,
        ], range: fullRange)
        textStorage.removeAttribute(.backgroundColor, range: fullRange)

        let nsText = textStorage.string as NSString

        applyRegex(textStorage, nsText: nsText, pattern: "^#{1,6}\\s+.*$",
                   color: headingColor, font: NSFont.boldSystemFont(ofSize: font.pointSize))
        applyRegex(textStorage, nsText: nsText, pattern: "^>+\\s*.*$",
                   color: blockquoteColor, font: nil)
        applyRegex(textStorage, nsText: nsText, pattern: "^(\\*{3,}|-{3,}|_{3,})\\s*$",
                   color: hrColor, font: nil)
        applyRegex(textStorage, nsText: nsText, pattern: "^(\\s*)([-*+])\\s",
                   color: nil, font: nil) { match in
            let r = match.range(at: 2)
            if r.location != NSNotFound {
                textStorage.addAttribute(.foregroundColor, value: self.listMarkerColor, range: r)
            }
        }
        applyRegex(textStorage, nsText: nsText, pattern: "^(\\s*)(\\d+\\.)\\s",
                   color: nil, font: nil) { match in
            let r = match.range(at: 2)
            if r.location != NSNotFound {
                textStorage.addAttribute(.foregroundColor, value: self.listMarkerColor, range: r)
            }
        }
        applyRegex(textStorage, nsText: nsText, pattern: "^\\s*[-*+]\\s+\\[([ xX])\\]",
                   color: nil, font: nil) { match in
            textStorage.addAttribute(.foregroundColor, value: self.listMarkerColor, range: match.range)
        }
        applyRegex(textStorage, nsText: nsText, pattern: "```[\\s\\S]*?```",
                   color: codeColor,
                   font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular),
                   options: [.dotMatchesLineSeparators],
                   backgroundColor: codeBgColor)
        applyRegex(textStorage, nsText: nsText, pattern: "`[^`\n]+`",
                   color: codeColor,
                   font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular),
                   backgroundColor: codeBgColor)
        applyRegex(textStorage, nsText: nsText, pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1",
                   color: boldColor,
                   font: NSFont.boldSystemFont(ofSize: font.pointSize))
        let italicFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic),
                                size: font.pointSize) ?? font
        applyRegex(textStorage, nsText: nsText, pattern: "(?<![*_])([*_])(?=\\S)(.+?)(?<=\\S)\\1(?![*_])",
                   color: italicColor, font: italicFont)
        applyRegex(textStorage, nsText: nsText, pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)",
                   color: linkColor, font: nil)
        applyRegex(textStorage, nsText: nsText, pattern: "!\\[([^\\]]*?)\\]\\(([^)]+)\\)",
                   color: linkColor, font: nil)

        textStorage.endEditing()
    }

    private func applyRegex(
        _ storage: NSTextStorage,
        nsText: NSString,
        pattern: String,
        color: NSColor?,
        font: NSFont?,
        options: NSRegularExpression.Options = [.anchorsMatchLines],
        backgroundColor: NSColor? = nil,
        _ markerCallback: ((NSTextCheckingResult) -> Void)? = nil
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let fullRange = NSRange(location: 0, length: nsText.length)
        for match in regex.matches(in: nsText as String, range: fullRange) {
            if let color {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
            if let font {
                storage.addAttribute(.font, value: font, range: match.range)
            }
            if let backgroundColor {
                storage.addAttribute(.backgroundColor, value: backgroundColor, range: match.range)
            }
            markerCallback?(match)
        }
    }
}

// MARK: - Line Number Gutter (standalone NSView, not NSRulerView subclass)

/// Draws line numbers in a standalone view placed beside the scroll view.
/// Avoids NSRulerView subclassing which breaks text rendering on macOS 26.
final class LineNumberGutterView: NSView {
    static let gutterWidth: CGFloat = 44
    private let gutterTextColor = NSColor(calibratedWhite: 0.45, alpha: 1)
    private let gutterBgColor = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)
    weak var textView: NSTextView?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        gutterBgColor.setFill()
        dirtyRect.fill()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = textView.enclosingScrollView else { return }

        let visibleRect = scrollView.contentView.bounds
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: gutterTextColor,
            .font: font,
        ]

        let string = textView.string as NSString
        guard string.length > 0 else { return }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var lineNumber = 1
        var index = 0
        while index < charRange.location {
            if string.character(at: index) == UInt16(UnicodeScalar("\n").value) {
                lineNumber += 1
            }
            index += 1
        }

        let insetY = textView.textContainerInset.height

        var charIndex = charRange.location
        while charIndex < NSMaxRange(charRange) {
            let lineRange = string.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: charIndex)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            // Convert from text view coordinates to gutter coordinates
            lineRect.origin.y += insetY - visibleRect.origin.y

            let numStr = "\(lineNumber)" as NSString
            let size = numStr.size(withAttributes: attrs)
            let x = Self.gutterWidth - size.width - 6
            let y = lineRect.origin.y + (lineRect.height - size.height) / 2
            numStr.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)

            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }
    }
}

// MARK: - Markdown Auto-Format Delegate

/// Handles Markdown auto-formatting (list continuation, blockquote continuation)
/// and text change notifications via NSTextViewDelegate.
final class MarkdownAutoFormatDelegate: NSObject, NSTextViewDelegate {
    var onTextChange: ((String) -> Void)?
    var highlighter: MarkdownHighlighter?

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        if let highlighter, let textStorage = textView.textStorage {
            DispatchQueue.main.async {
                highlighter.highlight(textStorage)
            }
        }
        onTextChange?(textView.string)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            return handleNewline(textView)
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            textView.insertText("    ", replacementRange: textView.selectedRange())
            return true
        }
        return false
    }

    private func handleNewline(_ textView: NSTextView) -> Bool {
        let cursorLocation = textView.selectedRange().location
        let nsStr = textView.string as NSString
        let lineRange = nsStr.lineRange(for: NSRange(location: cursorLocation, length: 0))
        let currentLine = nsStr.substring(with: lineRange)

        if let match = matchUnorderedList(currentLine) {
            let trimmed = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == String(match.marker) || trimmed == "\(match.marker) " {
                return clearLineAndInsertNewline(textView, lineRange: lineRange)
            }
            textView.insertNewline(nil)
            textView.insertText("\(match.indent)\(match.marker) ", replacementRange: textView.selectedRange())
            return true
        }

        if let match = matchOrderedList(currentLine) {
            let trimmed = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "\(match.number)." || trimmed == "\(match.number). " {
                return clearLineAndInsertNewline(textView, lineRange: lineRange)
            }
            textView.insertNewline(nil)
            textView.insertText("\(match.indent)\(match.number + 1). ", replacementRange: textView.selectedRange())
            return true
        }

        if let match = matchBlockquote(currentLine) {
            let trimmed = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == ">" || trimmed == "> " {
                return clearLineAndInsertNewline(textView, lineRange: lineRange)
            }
            textView.insertNewline(nil)
            textView.insertText(match.prefix, replacementRange: textView.selectedRange())
            return true
        }

        if let match = matchTaskList(currentLine) {
            let trimmed = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let emptyPatterns = [
                "\(match.marker) [ ]", "\(match.marker) [ ] ",
                "\(match.marker) [x]", "\(match.marker) [x] ",
                "\(match.marker) [X]", "\(match.marker) [X] ",
            ]
            if emptyPatterns.contains(trimmed) {
                return clearLineAndInsertNewline(textView, lineRange: lineRange)
            }
            textView.insertNewline(nil)
            textView.insertText("\(match.indent)\(match.marker) [ ] ", replacementRange: textView.selectedRange())
            return true
        }

        return false
    }

    private func clearLineAndInsertNewline(_ textView: NSTextView, lineRange: NSRange) -> Bool {
        if textView.shouldChangeText(in: lineRange, replacementString: "\n") {
            textView.replaceCharacters(in: lineRange, with: "\n")
            textView.didChangeText()
        }
        return true
    }

    // MARK: - Pattern matchers

    private struct UnorderedListMatch { let indent: String; let marker: Character }
    private struct OrderedListMatch { let indent: String; let number: Int }
    private struct BlockquoteMatch { let prefix: String }
    private struct TaskListMatch { let indent: String; let marker: Character }

    private func matchUnorderedList(_ line: String) -> UnorderedListMatch? {
        guard let regex = try? NSRegularExpression(pattern: "^(\\s*)([-*+])\\s") else { return nil }
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        if (try? NSRegularExpression(pattern: "^\\s*[-*+]\\s+\\[[ xX]\\]"))?.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)) != nil { return nil }
        return UnorderedListMatch(indent: ns.substring(with: m.range(at: 1)),
                                  marker: ns.substring(with: m.range(at: 2)).first ?? "-")
    }

    private func matchOrderedList(_ line: String) -> OrderedListMatch? {
        guard let regex = try? NSRegularExpression(pattern: "^(\\s*)(\\d+)\\.\\s") else { return nil }
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let num = Int(ns.substring(with: m.range(at: 2))) else { return nil }
        return OrderedListMatch(indent: ns.substring(with: m.range(at: 1)), number: num)
    }

    private func matchBlockquote(_ line: String) -> BlockquoteMatch? {
        guard let regex = try? NSRegularExpression(pattern: "^(>+\\s*)") else { return nil }
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return BlockquoteMatch(prefix: ns.substring(with: m.range(at: 1)))
    }

    private func matchTaskList(_ line: String) -> TaskListMatch? {
        guard let regex = try? NSRegularExpression(pattern: "^(\\s*)([-*+])\\s+\\[[ xX]\\]\\s") else { return nil }
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return TaskListMatch(indent: ns.substring(with: m.range(at: 1)),
                             marker: ns.substring(with: m.range(at: 2)).first ?? "-")
    }
}

// MARK: - Markdown Editor Window Controller

/// Creates and configures a standard NSTextView (no subclassing) with
/// Markdown highlighting, line numbers, and auto-format support.
final class MarkdownEditorWindowController: NSWindowController, NSWindowDelegate {
    private var textView: NSTextView!
    private var gutterView: LineNumberGutterView!
    private var autoFormatDelegate: MarkdownAutoFormatDelegate!
    private var highlighter: MarkdownHighlighter!
    private weak var scrollView: NSScrollView?
    private var keyMonitor: Any?
    private var isDirty = false
    private var baseTitle: String
    private var saveFn: (String) -> Void
    var onClose: (() -> Void)?

    init(initialText: String, onSave: @escaping (String) -> Void) {
        self.saveFn = onSave
        self.baseTitle = "Notes"
        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 560)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        window.title = baseTitle
        window.backgroundColor = NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 400, height: 300)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self

        let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let contentView = window.contentView!
        let editorBg = NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)
        let editorFg = MarkdownHighlighter.defaultColor
        let gutterW = LineNumberGutterView.gutterWidth

        // TextKit 1 stack (required for line number position queries)
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        // Line number gutter — standalone NSView on the left
        let gutter = LineNumberGutterView(frame: NSRect(x: 0, y: 0, width: gutterW, height: contentView.bounds.height))
        gutter.autoresizingMask = [.height]
        contentView.addSubview(gutter)
        gutterView = gutter

        // Scroll view fills the area right of the gutter
        let scrollFrame = NSRect(x: gutterW, y: 0,
                                 width: contentView.bounds.width - gutterW,
                                 height: contentView.bounds.height)
        let scrollView = NSScrollView(frame: scrollFrame)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = editorBg
        scrollView.drawsBackground = true
        scrollView.scrollerStyle = .overlay

        let contentSize = scrollView.contentSize
        let tv = NSTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        tv.minSize = NSSize(width: 0, height: contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 8, height: 8)

        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.usesFindBar = true

        tv.backgroundColor = editorBg
        tv.drawsBackground = true
        tv.insertionPointColor = NSColor.white
        tv.selectedTextAttributes = [
            .backgroundColor: NSColor(calibratedRed: 0.17, green: 0.33, blue: 0.53, alpha: 1),
            .foregroundColor: NSColor.white,
        ]
        tv.font = editorFont
        tv.textColor = editorFg
        tv.typingAttributes = [
            .font: editorFont,
            .foregroundColor: editorFg,
        ]

        tv.string = initialText
        scrollView.documentView = tv
        gutter.textView = tv

        // Syntax highlighter
        let syntaxHighlighter = MarkdownHighlighter(font: editorFont)
        highlighter = syntaxHighlighter
        syntaxHighlighter.highlight(textStorage)

        // Auto-format delegate
        let fmtDelegate = MarkdownAutoFormatDelegate()
        fmtDelegate.highlighter = syntaxHighlighter
        fmtDelegate.onTextChange = { [weak self, weak gutter] _ in
            gutter?.needsDisplay = true
            self?.markDirty()
        }
        tv.delegate = fmtDelegate
        autoFormatDelegate = fmtDelegate

        self.scrollView = scrollView
        textView = tv

        // Redraw gutter on scroll
        NotificationCenter.default.addObserver(self, selector: #selector(scrollOrTextDidChange),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true

        contentView.addSubview(scrollView)

        // The main app menu binds Cmd+F, Cmd+Z etc. to terminal-specific actions
        // that do not reach this window. Intercept them via local event monitor
        // and forward to the NSTextView's standard handlers.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard let chars = event.charactersIgnoringModifiers else { return event }

            // Cmd+S → Save
            if flags == [.command], chars == "s" {
                self.save()
                return nil
            }
            // Cmd+F → Find
            if flags == [.command], chars == "f" {
                let findItem = NSMenuItem()
                findItem.tag = 1  // showFindInterface
                self.textView.performFindPanelAction(findItem)
                return nil
            }
            // Cmd+Z → Undo
            if flags == [.command], chars == "z" {
                self.textView.undoManager?.undo()
                return nil
            }
            // Cmd+Shift+Z → Redo
            if flags == [.command, .shift], chars == "Z" {
                self.textView.undoManager?.redo()
                return nil
            }
            return event
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    @objc private func scrollOrTextDidChange(_ notification: Notification) {
        gutterView.needsDisplay = true
    }

    private func markDirty() {
        guard !isDirty else { return }
        isDirty = true
        window?.title = "* \(baseTitle)"
    }

    private func save() {
        guard isDirty else { return }
        saveFn(textView.string)
        isDirty = false
        window?.title = baseTitle
    }

    func showEditorWindow() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    func windowDidResize(_ notification: Notification) {
        guard let scrollView,
              let textContainer = textView.textContainer else { return }
        let contentSize = scrollView.contentSize
        textView.frame.size.width = contentSize.width
        textContainer.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        gutterView.needsDisplay = true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Unsaved Changes"
        alert.informativeText = "Do you want to save your changes before closing?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            save()
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }
}

import AppKit

// MARK: - Chat Message Model

private struct ChatMessage {
    enum Role {
        case user
        case assistant
        case error
    }
    let role: Role
    /// Text displayed in the chat UI.
    let content: String
    /// Text used when building AI prompts. Falls back to `content` if nil.
    let promptContent: String?

    init(role: Role, content: String, promptContent: String? = nil) {
        self.role = role
        self.content = content
        self.promptContent = promptContent
    }

    var effectivePromptContent: String {
        promptContent ?? content
    }
}

// MARK: - Flipped scroll content view

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - AI Chat Window Controller

final class AIChatWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private var messages: [ChatMessage] = []
    private var chatScrollView: NSScrollView!
    private var chatContentView: FlippedView!
    private var inputField: NSTextField!
    private var sendButton: NSButton!
    private var thinkingBubble: NSView?
    private var thinkingDots: [NSView] = []
    private var thinkingAnimationTimer: Timer?
    private var currentProcess: AIService.AIProcess?
    private let terminalContext: AIService.TerminalContext?
    private let configURL: URL

    init(
        initialPrompt: String? = nil,
        terminalContext: AIService.TerminalContext? = nil,
        configURL: URL = PtermDirectories.config
    ) {
        self.terminalContext = terminalContext
        self.configURL = configURL

        let contentRect = NSRect(x: 0, y: 0, width: 600, height: 500)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(contentRect: contentRect, styleMask: styleMask,
                              backing: .buffered, defer: false)
        window.title = "AI Assistant"
        window.minSize = NSSize(width: 400, height: 300)
        window.isReleasedWhenClosed = false
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1)

        super.init(window: window)
        window.delegate = self

        setupUI()

        if let prompt = initialPrompt, !prompt.isEmpty {
            sendMessage(prompt)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        currentProcess?.cancel()
        removeThinkingBubble()
    }

    // MARK: - Config Access

    private func loadAIConfig() -> AIConfiguration {
        PtermConfigStore.load(from: configURL).ai
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window else { return }
        let bounds = window.contentView!.bounds

        let rootView = FlippedView(frame: bounds)
        rootView.autoresizingMask = [.width, .height]
        window.contentView = rootView

        // Chat scroll view
        let inputAreaHeight: CGFloat = 48
        let scrollFrame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - inputAreaHeight)
        chatScrollView = NSScrollView(frame: scrollFrame)
        chatScrollView.autoresizingMask = [.width, .height]
        chatScrollView.hasVerticalScroller = true
        chatScrollView.autohidesScrollers = true
        chatScrollView.drawsBackground = false
        chatScrollView.borderType = .noBorder

        chatContentView = FlippedView(frame: NSRect(x: 0, y: 0, width: scrollFrame.width, height: 0))
        chatContentView.autoresizingMask = [.width]
        chatScrollView.documentView = chatContentView
        rootView.addSubview(chatScrollView)

        // Input area
        let inputAreaY = bounds.height - inputAreaHeight
        let inputArea = NSView(frame: NSRect(x: 0, y: inputAreaY, width: bounds.width, height: inputAreaHeight))
        inputArea.autoresizingMask = [.width, .minYMargin]
        inputArea.wantsLayer = true
        inputArea.layer?.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor

        // Separator line
        let separator = NSBox(frame: NSRect(x: 0, y: 0, width: bounds.width, height: 1))
        separator.autoresizingMask = [.width]
        separator.boxType = .separator
        inputArea.addSubview(separator)

        // Send button
        sendButton = NSButton(title: "Send", target: self, action: #selector(sendButtonClicked(_:)))
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        let sendWidth: CGFloat = 60
        sendButton.frame = NSRect(x: bounds.width - sendWidth - 12, y: 10, width: sendWidth, height: 28)
        sendButton.autoresizingMask = [.minXMargin]
        inputArea.addSubview(sendButton)

        // Input field
        let fieldX: CGFloat = 12
        let fieldWidth = bounds.width - fieldX - sendWidth - 24
        inputField = NSTextField(frame: NSRect(x: fieldX, y: 12, width: fieldWidth, height: 24))
        inputField.placeholderString = "Ask a question..."
        inputField.isEditable = true
        inputField.isBordered = true
        inputField.backgroundColor = NSColor(calibratedWhite: 0.2, alpha: 1)
        inputField.textColor = .white
        inputField.font = .systemFont(ofSize: 13)
        inputField.focusRingType = .none
        inputField.delegate = self
        inputField.autoresizingMask = [.width]
        inputArea.addSubview(inputField)

        rootView.addSubview(inputArea)

        window.initialFirstResponder = inputField
    }

    // MARK: - Chat Rendering

    private func rebuildChatView() {
        for subview in chatContentView.subviews {
            subview.removeFromSuperview()
        }

        let contentWidth = chatScrollView.bounds.width
        let padding: CGFloat = 16
        let maxBubbleWidth = contentWidth - padding * 2 - 40
        var y: CGFloat = 12

        for message in messages {
            let bubble = makeBubble(for: message, maxWidth: maxBubbleWidth)
            let bubbleHeight = bubble.frame.height

            let bubbleX: CGFloat
            switch message.role {
            case .user:
                bubbleX = contentWidth - bubble.frame.width - padding
            case .assistant, .error:
                bubbleX = padding
            }

            bubble.frame.origin = NSPoint(x: bubbleX, y: y)
            chatContentView.addSubview(bubble)
            y += bubbleHeight + 10
        }

        y += 12
        chatContentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: y)
        scrollToBottom()
    }

    private func makeBubble(for message: ChatMessage, maxWidth: CGFloat) -> NSView {
        let backgroundColor: NSColor
        let textColor: NSColor

        switch message.role {
        case .user:
            backgroundColor = NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.65, alpha: 1)
            textColor = .white
        case .assistant:
            backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 1)
            textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        case .error:
            backgroundColor = NSColor(calibratedRed: 0.5, green: 0.15, blue: 0.15, alpha: 1)
            textColor = .white
        }

        let textView = NSTextView()
        textView.string = message.content
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = textColor
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: maxWidth - 20, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let usedRect = textView.layoutManager!.usedRect(for: textView.textContainer!)
        let textWidth = min(ceil(usedRect.width) + 20, maxWidth)
        let textHeight = ceil(usedRect.height) + 16

        textView.frame = NSRect(x: 0, y: 0, width: textWidth, height: textHeight)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: textWidth, height: textHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = backgroundColor.cgColor
        container.layer?.cornerRadius = 10

        // Add copy button for assistant messages
        if message.role == .assistant {
            let copyButton = NSButton(title: "", target: self, action: #selector(copyBubbleText(_:)))
            copyButton.bezelStyle = .inline
            copyButton.isBordered = false
            if #available(macOS 11.0, *) {
                copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            } else {
                copyButton.title = "Copy"
            }
            copyButton.contentTintColor = NSColor(calibratedWhite: 0.6, alpha: 1)
            let buttonSize: CGFloat = 20
            copyButton.frame = NSRect(x: textWidth - buttonSize - 6, y: 4, width: buttonSize, height: buttonSize)
            copyButton.tag = messages.firstIndex(where: { $0.content == message.content && $0.role == message.role }) ?? 0
            container.addSubview(copyButton)
        }

        container.addSubview(textView)
        return container
    }

    @objc private func copyBubbleText(_ sender: NSButton) {
        let index = sender.tag
        guard messages.indices.contains(index) else { return }
        let text = messages[index].content
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func scrollToBottom() {
        let clipView = chatScrollView.contentView
        let documentHeight = chatContentView.frame.height
        let visibleHeight = clipView.bounds.height
        if documentHeight > visibleHeight {
            clipView.scroll(to: NSPoint(x: 0, y: documentHeight - visibleHeight))
        }
        chatScrollView.reflectScrolledClipView(clipView)
    }

    // MARK: - Send Message

    @objc private func sendButtonClicked(_ sender: NSButton) {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.stringValue = ""
        sendMessage(text)
    }

    private func sendMessage(_ text: String) {
        let aiConfig = loadAIConfig()

        guard aiConfig.enabled else {
            messages.append(ChatMessage(role: .error, content: AIService.AIError.aiDisabled.description))
            rebuildChatView()
            return
        }

        messages.append(ChatMessage(role: .user, content: text))
        rebuildChatView()
        setProcessing(true)

        // Build chat history for context (using promptContent, not display content)
        let history: [(role: String, content: String)] = messages.compactMap { msg in
            switch msg.role {
            case .user: return (role: "user", content: msg.effectivePromptContent)
            case .assistant: return (role: "assistant", content: msg.effectivePromptContent)
            case .error: return nil
            }
        }
        // Exclude the current message from history (it's already in the prompt)
        let previousHistory = history.count > 1 ? Array(history.dropLast()) : []

        let prompt = AIService.buildPrompt(
            question: text,
            language: aiConfig.language,
            context: terminalContext,
            chatHistory: previousHistory
        )

        currentProcess = AIService.invoke(model: aiConfig.model, prompt: prompt, workingDirectory: terminalContext?.workingDirectory) { [weak self] result in
            guard let self else { return }
            self.setProcessing(false)
            switch result {
            case .success(let response):
                self.messages.append(ChatMessage(role: .assistant, content: response))
            case .failure(let error):
                self.messages.append(ChatMessage(role: .error, content: error.description))
            }
            self.rebuildChatView()
        }

        if currentProcess == nil {
            // invoke returned nil — error was already dispatched to completion
        }
    }

    /// Send a summarization request for the given text.
    func sendSummarizeRequest(_ selectedText: String) {
        let aiConfig = loadAIConfig()

        guard aiConfig.enabled else {
            messages.append(ChatMessage(role: .error, content: AIService.AIError.aiDisabled.description))
            rebuildChatView()
            return
        }

        // Display: truncated preview for the chat UI
        let displayText = selectedText.count > 200
            ? String(selectedText.prefix(200)) + "..."
            : selectedText

        // Prompt: full summarization request built by AIService (includes language instruction)
        let prompt = AIService.buildSummarizePrompt(
            selectedText: selectedText,
            language: aiConfig.language,
            context: terminalContext
        )

        messages.append(ChatMessage(
            role: .user,
            content: "Summarize: \(displayText)",
            promptContent: prompt
        ))
        rebuildChatView()
        setProcessing(true)

        currentProcess = AIService.invoke(model: aiConfig.model, prompt: prompt, workingDirectory: terminalContext?.workingDirectory) { [weak self] result in
            guard let self else { return }
            self.setProcessing(false)
            switch result {
            case .success(let response):
                self.messages.append(ChatMessage(role: .assistant, content: response))
            case .failure(let error):
                self.messages.append(ChatMessage(role: .error, content: error.description))
            }
            self.rebuildChatView()
        }
    }

    private func setProcessing(_ processing: Bool) {
        if processing {
            sendButton.isEnabled = false
            inputField.isEnabled = false
            showThinkingBubble()
        } else {
            removeThinkingBubble()
            sendButton.isEnabled = true
            inputField.isEnabled = true
            window?.makeFirstResponder(inputField)
        }
    }

    // MARK: - Thinking Bubble Animation

    private func showThinkingBubble() {
        removeThinkingBubble()

        let contentWidth = chatScrollView.bounds.width
        let padding: CGFloat = 16
        let bubbleWidth: CGFloat = 80
        let bubbleHeight: CGFloat = 40
        let dotSize: CGFloat = 10
        let dotSpacing: CGFloat = 8

        let bubble = NSView(frame: NSRect(x: padding, y: 0, width: bubbleWidth, height: bubbleHeight))
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = NSColor(calibratedRed: 0.2, green: 0.5, blue: 1.0, alpha: 0.25).cgColor
        bubble.layer?.cornerRadius = 12
        bubble.layer?.borderWidth = 1
        bubble.layer?.borderColor = NSColor(calibratedRed: 0.3, green: 0.6, blue: 1.0, alpha: 0.5).cgColor

        let totalDotsWidth = dotSize * 3 + dotSpacing * 2
        let startX = (bubbleWidth - totalDotsWidth) / 2

        var dots: [NSView] = []
        for i in 0..<3 {
            let dot = NSView(frame: NSRect(
                x: startX + CGFloat(i) * (dotSize + dotSpacing),
                y: (bubbleHeight - dotSize) / 2,
                width: dotSize,
                height: dotSize
            ))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor(calibratedRed: 0.4, green: 0.7, blue: 1.0, alpha: 1.0).cgColor
            dot.layer?.cornerRadius = dotSize / 2
            bubble.addSubview(dot)
            dots.append(dot)
        }
        thinkingDots = dots

        // Position below the last message
        let lastSubview = chatContentView.subviews.last
        let bubbleY = (lastSubview?.frame.maxY ?? 0) + 10
        bubble.frame.origin = NSPoint(x: padding, y: bubbleY)

        chatContentView.addSubview(bubble)
        thinkingBubble = bubble

        // Expand content view to fit
        let neededHeight = bubble.frame.maxY + 20
        if chatContentView.frame.height < neededHeight {
            chatContentView.frame.size.height = neededHeight
        }
        scrollToBottom()

        // Animate dots with bouncing pulse
        var animationStep = 0
        thinkingAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let activeDot = animationStep % 3
            for (i, dot) in self.thinkingDots.enumerated() {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.allowsImplicitAnimation = true
                    if i == activeDot {
                        dot.layer?.backgroundColor = NSColor(calibratedRed: 0.3, green: 0.8, blue: 1.0, alpha: 1.0).cgColor
                        dot.layer?.transform = CATransform3DMakeScale(1.4, 1.4, 1)
                    } else {
                        dot.layer?.backgroundColor = NSColor(calibratedRed: 0.4, green: 0.7, blue: 1.0, alpha: 0.5).cgColor
                        dot.layer?.transform = CATransform3DIdentity
                    }
                }
            }
            animationStep += 1
        }
    }

    private func removeThinkingBubble() {
        thinkingAnimationTimer?.invalidate()
        thinkingAnimationTimer = nil
        thinkingDots.removeAll()
        thinkingBubble?.removeFromSuperview()
        thinkingBubble = nil
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            sendButtonClicked(sendButton)
            return true
        }
        return false
    }
}

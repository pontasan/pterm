import Foundation

/// Manages AI CLI invocations for terminal AI features.
///
/// Each AI model is invoked through its respective CLI tool installed on the system.
/// Communication is asynchronous and non-blocking to the UI.
enum AIService {
    /// Error types for AI service operations.
    enum AIError: Error, CustomStringConvertible {
        case cliNotFound(AIModelType)
        case invocationFailed(String)
        case aiDisabled
        case processTerminated(Int32)

        var description: String {
            switch self {
            case .cliNotFound(let model):
                return "CLI not found for \(model.displayName). Please install the CLI tool first."
            case .invocationFailed(let message):
                return "AI invocation failed: \(message)"
            case .aiDisabled:
                return "AI features are disabled. Enable them in Settings > AI."
            case .processTerminated(let code):
                return "AI process terminated with exit code \(code)."
            }
        }
    }

    /// A running AI process that can be cancelled.
    final class AIProcess: @unchecked Sendable {
        private let process: Process
        private let stdoutPipe: Pipe
        private let stderrPipe: Pipe
        private let lock = NSLock()
        private var _isCancelled = false

        var isCancelled: Bool {
            lock.withLock { _isCancelled }
        }

        fileprivate init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
            self.process = process
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
        }

        func cancel() {
            lock.withLock { _isCancelled = true }
            if process.isRunning {
                process.terminate()
            }
        }

        fileprivate func waitForResult() throws -> String {
            process.waitUntilExit()

            if isCancelled {
                throw AIError.invocationFailed("Operation was cancelled.")
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            let exitCode = process.terminationStatus
            if exitCode != 0 {
                let errorOutput = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !errorOutput.isEmpty {
                    throw AIError.invocationFailed(errorOutput)
                }
                throw AIError.processTerminated(exitCode)
            }

            return (String(data: stdoutData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Context information provided to the AI for richer responses.
    struct TerminalContext {
        let workingDirectory: String
        let foregroundProcess: String?
        let viewportText: String
    }

    /// Resolves the full path of a CLI executable.
    ///
    /// Security: Only searches system-managed directories that require
    /// administrator privileges to modify.  User-writable directories
    /// (e.g. ~/.local/bin, ~/.npm-global/bin) are excluded to prevent
    /// path hijack attacks where a malicious binary could steal API keys
    /// passed via environment variables.
    ///
    /// After resolving a candidate path, the executable is validated via
    /// `codesign --verify` to ensure it has not been tampered with and
    /// carries a valid code signature.
    private static func resolveExecutable(for model: AIModelType) -> String? {
        let name: String
        switch model {
        case .claudeCode: name = "claude"
        case .codex: name = "codex"
        case .gemini: name = "gemini"
        }

        // Only search directories that require root/admin to write to.
        // User-writable paths (~/.local/bin, ~/.npm-global/bin, ~/.cargo/bin)
        // are intentionally excluded to prevent path hijack attacks.
        let searchPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin"
        ]

        for dir in searchPaths {
            let fullPath = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: fullPath),
               verifyCodeSignature(atPath: fullPath) {
                return fullPath
            }
        }

        // Fallback: try `which` via shell, but validate the result is in a
        // trusted directory and has a valid code signature.
        let whichProcess = Process()
        let whichPipe = Pipe()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        whichProcess.arguments = ["which", name]
        whichProcess.standardOutput = whichPipe
        whichProcess.standardError = FileHandle.nullDevice
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0 {
                let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                let path = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty,
                   FileManager.default.isExecutableFile(atPath: path),
                   !isUserWritableDirectory(path),
                   verifyCodeSignature(atPath: path) {
                    return path
                }
            }
        } catch {
            // which failed, continue
        }

        return nil
    }

    /// Check if a file path resides under a user-writable directory.
    ///
    /// Rejects paths under the user's home directory to prevent path hijack
    /// attacks where a malicious binary in ~/.local/bin etc. could steal
    /// API keys passed via environment variables.
    private static func isUserWritableDirectory(_ path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        let home = NSHomeDirectory()
        return resolved.hasPrefix(home + "/")
    }

    /// Verify that an executable at the given path has a valid code signature.
    ///
    /// Uses `codesign --verify` to check the signature.  Unsigned or
    /// tampered executables are rejected to prevent supply chain attacks.
    private static func verifyCodeSignature(atPath path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Build the CLI arguments for a given model and prompt.
    private static func buildArguments(
        for model: AIModelType,
        prompt: String,
        dangerouslySkipPermissions: Bool
    ) -> [String] {
        switch model {
        case .claudeCode:
            var args = ["-p"]
            if dangerouslySkipPermissions {
                args.append("--dangerously-skip-permissions")
            }
            args.append(prompt)
            return args
        case .codex:
            return ["exec", "--full-auto", "--skip-git-repo-check", prompt]
        case .gemini:
            return ["-y", "-p", prompt]
        }
    }

    /// Resolve a language identifier to a descriptive name suitable for AI prompts.
    ///
    /// Uses `NSLocale` directly to avoid the app-bundle localization issue where
    /// `Locale(identifier:).localizedString(forIdentifier:)` returns the name
    /// based on the app's supported localizations rather than the requested locale.
    ///
    /// Returns both a self-localized name (e.g. "日本語") and an English name (e.g. "Japanese")
    /// so the AI can unambiguously identify the target language.
    private static func languageDescription(for identifier: String) -> String {
        let selfLocale = NSLocale(localeIdentifier: identifier)
        let selfName = selfLocale.displayName(forKey: .identifier, value: identifier) ?? identifier
        let englishLocale = NSLocale(localeIdentifier: "en_US")
        let englishName = englishLocale.displayName(forKey: .identifier, value: identifier) ?? identifier
        if selfName == englishName {
            return englishName
        }
        return "\(selfName) (\(englishName))"
    }

    /// Build a complete prompt with context and language instruction.
    static func buildPrompt(
        question: String,
        language: String,
        context: TerminalContext?,
        chatHistory: [(role: String, content: String)]
    ) -> String {
        var parts: [String] = []

        let langDesc = languageDescription(for: language)
        parts.append("IMPORTANT: You MUST respond entirely in \(langDesc). Every part of your response — including explanations, labels, and descriptions — MUST be written in \(langDesc). Do NOT use any other language under any circumstances.")

        // Terminal context
        if let ctx = context {
            parts.append("Current working directory: \(ctx.workingDirectory)")
            if let proc = ctx.foregroundProcess, !proc.isEmpty {
                parts.append("Running process: \(proc)")
            }
            if !ctx.viewportText.isEmpty {
                parts.append("Terminal viewport content (recent output):\n```\n\(ctx.viewportText)\n```")
            }
        }

        // Chat history
        if !chatHistory.isEmpty {
            parts.append("Conversation history:")
            for entry in chatHistory {
                let role = entry.role == "user" ? "User" : "Assistant"
                parts.append("\(role): \(entry.content)")
            }
        }

        parts.append("User question: \(question)")

        parts.append("REMINDER: Your ENTIRE response MUST be in \(langDesc). This is mandatory.")

        return parts.joined(separator: "\n\n")
    }

    /// Build a summarization prompt for selected text.
    static func buildSummarizePrompt(
        selectedText: String,
        language: String,
        context: TerminalContext?
    ) -> String {
        var parts: [String] = []

        let langDesc = languageDescription(for: language)
        parts.append("IMPORTANT: You MUST respond entirely in \(langDesc). Every part of your response — including explanations, labels, and descriptions — MUST be written in \(langDesc). Do NOT use any other language under any circumstances.")

        if let ctx = context {
            parts.append("Current working directory: \(ctx.workingDirectory)")
            if let proc = ctx.foregroundProcess, !proc.isEmpty {
                parts.append("Running process: \(proc)")
            }
        }

        parts.append("Analyze and summarize the following terminal output. Explain what it means, highlight any errors or important information:\n```\n\(selectedText)\n```")

        parts.append("REMINDER: Your ENTIRE response MUST be in \(langDesc). This is mandatory.")

        return parts.joined(separator: "\n\n")
    }

    /// The set of environment variable keys considered safe to pass to AI subprocesses.
    private static let safeEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "TERM", "LANG", "LC_ALL", "LC_CTYPE",
        "SHELL", "USER", "LOGNAME", "TMPDIR",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME"
    ]

    /// Known environment variable prefixes used by AI providers for authentication.
    private static let aiProviderEnvPrefixes: [AIModelType: [String]] = [
        .claudeCode: ["ANTHROPIC_"],
        .codex: ["OPENAI_"],
        .gemini: ["GEMINI_", "GOOGLE_"]
    ]

    /// Build a minimal, safe environment for the AI subprocess.
    ///
    /// Only passes through well-known safe variables and provider-specific
    /// API keys, preventing accidental leakage of secrets or credentials
    /// from the parent process environment.
    private static func buildSafeEnvironment(for model: AIModelType) -> [String: String] {
        let fullEnv = ProcessInfo.processInfo.environment
        var safeEnv: [String: String] = [:]

        // Copy safe keys
        for key in safeEnvironmentKeys {
            if let value = fullEnv[key] {
                safeEnv[key] = value
            }
        }

        // Copy AI provider-specific keys
        let prefixes = aiProviderEnvPrefixes[model] ?? []
        for (key, value) in fullEnv {
            if prefixes.contains(where: { key.hasPrefix($0) }) {
                safeEnv[key] = value
            }
        }

        return safeEnv
    }

    /// Invoke the AI CLI asynchronously.
    ///
    /// - Parameters:
    ///   - model: The AI model to use.
    ///   - prompt: The full prompt string.
    ///   - aiConfig: The AI configuration controlling behavior flags.
    ///   - completion: Called on the main thread with the result.
    /// - Returns: An AIProcess handle that can be used to cancel the operation.
    @discardableResult
    static func invoke(
        model: AIModelType,
        prompt: String,
        workingDirectory: String? = nil,
        aiConfig: AIConfiguration = .default,
        completion: @escaping (Result<String, AIError>) -> Void
    ) -> AIProcess? {
        guard let executablePath = resolveExecutable(for: model) else {
            DispatchQueue.main.async {
                completion(.failure(.cliNotFound(model)))
            }
            return nil
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        let args = buildArguments(
            for: model,
            prompt: prompt,
            dangerouslySkipPermissions: aiConfig.dangerouslySkipPermissions
        )
        process.arguments = args
        process.standardOutput = stdoutPipe

        process.standardError = stderrPipe
        process.environment = buildSafeEnvironment(for: model)
        if let dir = workingDirectory {
            let dirURL = URL(fileURLWithPath: dir)
            if FileManager.default.fileExists(atPath: dir) {
                process.currentDirectoryURL = dirURL
            }
        }

        let aiProcess = AIProcess(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                let result = try aiProcess.waitForResult()
                DispatchQueue.main.async {
                    if !aiProcess.isCancelled {
                        completion(.success(result))
                    }
                }
            } catch let error as AIError {
                DispatchQueue.main.async {
                    if !aiProcess.isCancelled {
                        completion(.failure(error))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if !aiProcess.isCancelled {
                        completion(.failure(.invocationFailed(error.localizedDescription)))
                    }
                }
            }
        }

        return aiProcess
    }
}

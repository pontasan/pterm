import Foundation
import Network
import Security

struct MCPToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: Any]

    var jsonObject: [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema
        ]
    }
}

protocol MCPToolProvider: AnyObject {
    func toolDefinitions() -> [MCPToolDefinition]
    func callTool(named name: String, arguments: [String: Any]) throws -> String
}

enum MCPServerError: LocalizedError {
    case invalidRequest
    case unsupportedMethod(String)
    case toolNotFound(String)
    case unauthorized
    case payloadTooLarge
    case commandNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Invalid MCP request."
        case .unsupportedMethod(let method):
            return "Unsupported MCP method: \(method)"
        case .toolNotFound(let name):
            return "Unknown MCP tool: \(name)"
        case .unauthorized:
            return "Unauthorized: invalid or missing authentication token."
        case .payloadTooLarge:
            return "Request payload exceeds maximum allowed size."
        case .commandNotAllowed(let reason):
            return "Command not allowed: \(reason)"
        }
    }
}

final class MCPServer {
    private let configuration: MCPServerConfiguration
    private weak var toolProvider: MCPToolProvider?
    private let queue = DispatchQueue(label: "com.pterm.mcp-server", qos: .userInitiated)
    private var listener: NWListener?
    private let authToken: String
    private let tokenFileURL: URL

    /// Maximum request buffer size: 1 MB. Requests exceeding this are rejected with 413.
    static let maximumRequestBufferSize = 1_048_576

    init(configuration: MCPServerConfiguration, toolProvider: MCPToolProvider) {
        self.configuration = configuration
        self.toolProvider = toolProvider
        self.authToken = Self.generateToken()
        self.tokenFileURL = PtermDirectories.base.appendingPathComponent("mcp-token")
    }

    var port: Int { configuration.port }

    func start() throws {
        // Write auth token to file with 0600 permissions before accepting connections.
        try writeTokenFile()

        // Bind exclusively to the loopback interface (127.0.0.1).
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: UInt16(configuration.port))!
        )

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("pterm MCP server failed: \(error.localizedDescription)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        removeTokenFile()
    }

    // MARK: - Token Authentication

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            fatalError("Failed to generate cryptographically random MCP auth token (SecRandomCopyBytes status: \(status))")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func writeTokenFile() throws {
        let fm = FileManager.default
        let dir = tokenFileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }

        // Remove any pre-existing file/symlink before writing to prevent a
        // symlink attack where an attacker replaces the token path with a link
        // to an attacker-controlled location.
        try? fm.removeItem(at: tokenFileURL)

        // Open with O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW so that a symlink
        // at the token path causes the write to fail rather than follow the link.
        let path = tokenFileURL.path
        let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw MCPServerError.invalidRequest
        }
        defer { close(fd) }

        let tokenData = Array(authToken.utf8)
        let written = tokenData.withUnsafeBufferPointer { buf in
            Darwin.write(fd, buf.baseAddress!, buf.count)
        }
        guard written == tokenData.count else {
            throw MCPServerError.invalidRequest
        }
    }

    private func removeTokenFile() {
        try? FileManager.default.removeItem(at: tokenFileURL)
    }

    // MARK: - Connection Handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finish(connection)
                NSLog("pterm MCP connection receive error: \(error.localizedDescription)")
                return
            }

            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            // Enforce maximum buffer size to prevent denial-of-service via oversized requests.
            if accumulated.count > Self.maximumRequestBufferSize {
                let response = self.httpResponse(
                    status: 413,
                    body: self.errorBody(code: -32600, message: "Payload too large", id: nil)
                )
                self.send(response: response, on: connection)
                return
            }

            if let parsed = self.parseHTTPRequest(from: accumulated) {
                let response: Data
                if !parsed.authorized {
                    // Allow unauthenticated access to auth/info so clients can
                    // discover how to obtain a session token.
                    if let unauthResponse = self.handleUnauthenticatedRequest(parsed.body) {
                        response = unauthResponse
                    } else {
                        response = self.httpResponse(
                            status: 401,
                            body: self.errorBody(
                                code: -32000,
                                message: "Unauthorized: invalid or missing authentication token. "
                                    + "Call the \"auth/info\" method without authentication to learn how to obtain a token.",
                                id: self.extractRequestID(from: parsed.body))
                        )
                    }
                } else {
                    response = self.handleRequest(parsed.body)
                }
                self.send(response: response, on: connection)
                return
            }

            if isComplete {
                self.send(response: self.httpResponse(status: 400, body: self.errorBody(code: -32600, message: "Malformed HTTP request", id: nil)), on: connection)
                return
            }

            self.receiveRequest(on: connection, buffer: accumulated)
        }
    }

    private struct ParsedHTTPRequest {
        let body: Data
        let authorized: Bool
    }

    /// Parse HTTP request, extracting the body and checking the Authorization header.
    /// Returns nil if the request is incomplete (needs more data).
    /// Returns a ParsedHTTPRequest with an empty body for malformed but complete requests.
    private func parseHTTPRequest(from data: Data) -> ParsedHTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return ParsedHTTPRequest(body: Data(), authorized: false)
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, requestLine.hasPrefix("POST ") else {
            return ParsedHTTPRequest(body: Data(), authorized: false)
        }

        // Extract headers
        var contentLength = 0
        var bearerToken: String?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let headerName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let headerValue = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            if headerName.caseInsensitiveCompare("Content-Length") == .orderedSame {
                let parsed = Int(headerValue) ?? 0
                guard parsed >= 0, parsed <= Self.maximumRequestBufferSize else {
                    return ParsedHTTPRequest(body: Data(), authorized: false)
                }
                contentLength = parsed
            } else if headerName.caseInsensitiveCompare("Authorization") == .orderedSame {
                if headerValue.hasPrefix("Bearer ") {
                    bearerToken = String(headerValue.dropFirst("Bearer ".count))
                }
            }
        }

        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else {
            return nil
        }

        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))

        // Constant-time token comparison to prevent timing attacks.
        let authorized: Bool
        if let token = bearerToken, token.count == authToken.count {
            let tokenBytes = Array(token.utf8)
            let expectedBytes = Array(authToken.utf8)
            var diff: UInt8 = 0
            for i in 0..<tokenBytes.count {
                diff |= tokenBytes[i] ^ expectedBytes[i]
            }
            authorized = diff == 0
        } else {
            authorized = false
        }

        return ParsedHTTPRequest(body: body, authorized: authorized)
    }

    // MARK: - Unauthenticated Endpoint

    /// Handle a limited set of methods that do not require authentication.
    /// Returns a response if the method is allowed unauthenticated, nil otherwise.
    private func handleUnauthenticatedRequest(_ body: Data) -> Data? {
        guard !body.isEmpty,
              let jsonObject = try? JSONSerialization.jsonObject(with: body),
              let request = jsonObject as? [String: Any],
              let method = request["method"] as? String,
              method == "auth/info" else {
            return nil
        }
        let id = request["id"]
        let result: [String: Any] = [
            "token_file": tokenFileURL.path,
            "auth_scheme": "Bearer",
            "header_format": "Authorization: Bearer <token>",
            "instructions": "Read the session token from the file at token_file (permissions 0600, owner-only). "
                + "Include it in every subsequent request as an HTTP header: Authorization: Bearer <token>. "
                + "The token is regenerated each time pterm starts."
        ]
        return httpResponse(status: 200, body: responseBody(id: id, result: result))
    }

    /// Extract the JSON-RPC "id" field from raw body data, returning nil on failure.
    private func extractRequestID(from body: Data) -> Any? {
        guard !body.isEmpty,
              let jsonObject = try? JSONSerialization.jsonObject(with: body),
              let request = jsonObject as? [String: Any] else {
            return nil
        }
        return request["id"]
    }

    private func handleRequest(_ body: Data) -> Data {
        guard !body.isEmpty else {
            return httpResponse(status: 400, body: errorBody(code: -32600, message: "Empty request body", id: nil))
        }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: body),
              let request = jsonObject as? [String: Any] else {
            return httpResponse(status: 400, body: errorBody(code: -32700, message: "Invalid JSON payload", id: nil))
        }

        let id = request["id"]
        guard let method = request["method"] as? String else {
            return httpResponse(status: 400, body: errorBody(code: -32600, message: "Missing method", id: id))
        }

        do {
            let result = try dispatch(method: method, params: request["params"] as? [String: Any] ?? [:])
            return httpResponse(status: 200, body: responseBody(id: id, result: result))
        } catch {
            return httpResponse(
                status: 200,
                body: errorBody(code: -32000, message: error.localizedDescription, id: id)
            )
        }
    }

    private func dispatch(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            return [
                "protocolVersion": "2025-03-26",
                "capabilities": [
                    "tools": [:]
                ],
                "serverInfo": [
                    "name": "pterm-mcp",
                    "version": "1.0"
                ]
            ]
        case "notifications/initialized":
            return [:]
        case "ping":
            return [:]
        case "auth/info":
            return [
                "token_file": tokenFileURL.path,
                "auth_scheme": "Bearer",
                "header_format": "Authorization: Bearer <token>",
                "instructions": "Read the session token from the file at token_file (permissions 0600, owner-only). "
                    + "Include it in every subsequent request as an HTTP header: Authorization: Bearer <token>. "
                    + "The token is regenerated each time pterm starts."
            ]
        case "tools/list":
            let tools = try performOnMain {
                self.toolProvider?.toolDefinitions().map(\.jsonObject) ?? []
            }
            return ["tools": tools]
        case "tools/call":
            guard let name = params["name"] as? String else {
                throw MCPServerError.invalidRequest
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let text = try performOnMain {
                guard let toolProvider = self.toolProvider else {
                    throw MCPServerError.toolNotFound(name)
                }
                return try toolProvider.callTool(named: name, arguments: arguments)
            }
            return [
                "content": [
                    [
                        "type": "text",
                        "text": text
                    ]
                ],
                "isError": false
            ]
        default:
            throw MCPServerError.unsupportedMethod(method)
        }
    }

    private func performOnMain<T>(_ body: () throws -> T) throws -> T {
        if Thread.isMainThread {
            return try body()
        }

        var result: Result<T, Error>!
        DispatchQueue.main.sync {
            result = Result { try body() }
        }
        return try result.get()
    }

    private func responseBody(id: Any?, result: [String: Any]) -> Data {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id {
            payload["id"] = id
        } else {
            payload["id"] = NSNull()
        }
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }

    private func errorBody(code: Int, message: String, id: Any?) -> Data {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ]
        ]
        payload["id"] = id ?? NSNull()
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }

    private func httpResponse(status: Int, body: Data) -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 413: statusText = "Payload Too Large"
        default: statusText = "Error"
        }

        var response = Data()
        response.append("HTTP/1.1 \(status) \(statusText)\r\n".data(using: .utf8)!)
        response.append("Content-Type: application/json\r\n".data(using: .utf8)!)
        response.append("Content-Length: \(body.count)\r\n".data(using: .utf8)!)
        response.append("Connection: close\r\n\r\n".data(using: .utf8)!)
        response.append(body)
        return response
    }

    private func send(response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.finish(connection)
        })
    }

    private func finish(_ connection: NWConnection) {
        connection.cancel()
    }

    // MARK: - Command Validation

    /// Validate that a command path is safe for execution via MCP.
    /// - The path must be absolute.
    /// - The path must resolve to a regular file (not a symlink to an unexpected location).
    /// - The file must exist.
    static func validateCommandPath(_ command: String) throws {
        // Must be an absolute path
        guard command.hasPrefix("/") else {
            throw MCPServerError.commandNotAllowed("command must be an absolute path, got: \(command)")
        }

        let fm = FileManager.default

        // Resolve symlinks to get the real path and verify the target exists
        let resolvedPath = (command as NSString).resolvingSymlinksInPath

        // The resolved file must exist
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            throw MCPServerError.commandNotAllowed("executable does not exist: \(command)")
        }

        // Must be a regular file, not a directory
        guard !isDirectory.boolValue else {
            throw MCPServerError.commandNotAllowed("path is a directory, not an executable: \(command)")
        }

        // Verify the file is executable
        guard fm.isExecutableFile(atPath: resolvedPath) else {
            throw MCPServerError.commandNotAllowed("file is not executable: \(command)")
        }
    }
}

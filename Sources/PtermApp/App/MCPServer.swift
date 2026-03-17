import Foundation
import Network

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

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Invalid MCP request."
        case .unsupportedMethod(let method):
            return "Unsupported MCP method: \(method)"
        case .toolNotFound(let name):
            return "Unknown MCP tool: \(name)"
        }
    }
}

final class MCPServer {
    private let configuration: MCPServerConfiguration
    private weak var toolProvider: MCPToolProvider?
    private let queue = DispatchQueue(label: "com.pterm.mcp-server", qos: .userInitiated)
    private var listener: NWListener?

    init(configuration: MCPServerConfiguration, toolProvider: MCPToolProvider) {
        self.configuration = configuration
        self.toolProvider = toolProvider
    }

    var port: Int { configuration.port }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(configuration.port))!)
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
    }

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

            if let request = self.extractRequest(from: accumulated) {
                let response = self.handleRequest(request)
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

    private func extractRequest(from data: Data) -> Data? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return Data()
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, requestLine.hasPrefix("POST ") else {
            return Data()
        }
        let contentLength = lines
            .dropFirst()
            .compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                guard parts[0].trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Content-Length") == .orderedSame else {
                    return nil
                }
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .first ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else {
            return nil
        }
        return data.subdata(in: bodyStart..<(bodyStart + contentLength))
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
}

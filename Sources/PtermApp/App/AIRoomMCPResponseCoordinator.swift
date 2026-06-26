import Foundation

enum AIRoomMCPError: LocalizedError {
    case missingCallerTerminalID
    case invalidCallerTerminalID(String)
    case callerTerminalNotFound(UUID)
    case targetTerminalNotFound(UUID)
    case notInRoom
    case targetBusy(UUID)
    case requestCancelled
    case responseBufferExceeded
    case invalidMarkerConfiguration

    var errorDescription: String? {
        switch self {
        case .missingCallerTerminalID:
            return "Missing X-Pterm-Terminal-Id header."
        case .invalidCallerTerminalID(let value):
            return "Invalid X-Pterm-Terminal-Id header: \(value)"
        case .callerTerminalNotFound(let id):
            return "Caller terminal was not found: \(id.uuidString)"
        case .targetTerminalNotFound(let id):
            return "Target terminal was not found: \(id.uuidString)"
        case .notInRoom:
            return "The target terminal is not visible from any room joined by the caller terminal."
        case .targetBusy(let id):
            return "Target terminal is already waiting for an AI room response: \(id.uuidString)"
        case .requestCancelled:
            return "AI room response wait was cancelled."
        case .responseBufferExceeded:
            return "AI room response buffer exceeded the maximum size."
        case .invalidMarkerConfiguration:
            return "AI response begin/end markers must be non-empty and distinct."
        }
    }
}

final class AIRoomMCPResponseCoordinator {
    final class PendingRequest {
        let id = UUID()
        let callerTerminalID: UUID
        let targetTerminalID: UUID
        let beginMarker: String
        let endMarker: String
        let maxBufferCharacterCount: Int
        let startedAt = Date()
        fileprivate var buffer = ""
        fileprivate let ignoredMarkerBodyFingerprints: Set<String>
        fileprivate var completedResponse: String?
        fileprivate var failure: AIRoomMCPError?

        init(
            callerTerminalID: UUID,
            targetTerminalID: UUID,
            beginMarker: String,
            endMarker: String,
            maxBufferCharacterCount: Int,
            ignoredMarkerBodies: [String]
        ) {
            self.callerTerminalID = callerTerminalID
            self.targetTerminalID = targetTerminalID
            self.beginMarker = beginMarker
            self.endMarker = endMarker
            self.maxBufferCharacterCount = maxBufferCharacterCount
            self.ignoredMarkerBodyFingerprints = Set(
                ignoredMarkerBodies
                    .map(AIRoomMCPResponseCoordinator.markerBodyFingerprint)
                    .filter { !$0.isEmpty }
            )
        }
    }

    enum RequestState {
        case waiting
        case completed(String)
        case failed(AIRoomMCPError)
    }

    private let lock = NSLock()
    private var pendingByTargetTerminalID: [UUID: PendingRequest] = [:]
    private var pendingByCallerTerminalID: [UUID: PendingRequest] = [:]

    func beginRequest(
        callerTerminalID: UUID,
        targetTerminalID: UUID,
        beginMarker: String,
        endMarker: String,
        ignoredInitialMarkerBody: String? = nil,
        ignoredMarkerBodies: [String] = [],
        maxBufferCharacterCount: Int = 1_048_576
    ) throws -> PendingRequest {
        let normalizedBegin = beginMarker.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEnd = endMarker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBegin.isEmpty,
              !normalizedEnd.isEmpty,
              normalizedBegin != normalizedEnd else {
            throw AIRoomMCPError.invalidMarkerConfiguration
        }

        lock.lock()
        defer { lock.unlock() }

        if let existing = pendingByTargetTerminalID[targetTerminalID] {
            if existing.callerTerminalID != callerTerminalID {
                throw AIRoomMCPError.targetBusy(targetTerminalID)
            }
            cancelLocked(existing)
        }
        if let existing = pendingByCallerTerminalID[callerTerminalID] {
            cancelLocked(existing)
        }

        let request = PendingRequest(
            callerTerminalID: callerTerminalID,
            targetTerminalID: targetTerminalID,
            beginMarker: normalizedBegin,
            endMarker: normalizedEnd,
            maxBufferCharacterCount: maxBufferCharacterCount,
            ignoredMarkerBodies: ignoredMarkerBodies + (ignoredInitialMarkerBody.map { [$0] } ?? [])
        )
        pendingByTargetTerminalID[targetTerminalID] = request
        pendingByCallerTerminalID[callerTerminalID] = request
        return request
    }

    @discardableResult
    func appendOutputCodepoint(_ codepoint: UInt32, terminalID: UUID) -> RequestState {
        guard let scalar = UnicodeScalar(codepoint) else { return .waiting }

        lock.lock()
        defer { lock.unlock() }
        guard let request = pendingByTargetTerminalID[terminalID],
              request.completedResponse == nil,
              request.failure == nil else {
            return .waiting
        }

        request.buffer.unicodeScalars.append(scalar)
        if request.buffer.count > request.maxBufferCharacterCount {
            failLocked(request, error: .responseBufferExceeded)
            return .failed(.responseBufferExceeded)
        }

        guard Self.hasCompletedEndMarkerAtBufferTail(request.buffer, endMarker: request.endMarker) else {
            return .waiting
        }

        while let extracted = Self.extractFirstCompleteResponse(
            from: request.buffer,
            beginMarker: request.beginMarker,
            endMarker: request.endMarker
        ) {
            if Self.shouldIgnoreMarkerBody(
                extracted.body,
                ignoredMarkerBodyFingerprints: request.ignoredMarkerBodyFingerprints
            ) {
                request.buffer.removeSubrange(..<extracted.endRange.upperBound)
                continue
            }

            request.completedResponse = extracted.body.trimmingCharacters(in: .whitespacesAndNewlines)
            removeLocked(request)
            return .completed(request.completedResponse ?? "")
        }
        return .waiting
    }

    func completeIfResponsePresent(in text: String, for request: PendingRequest) -> RequestState {
        lock.lock()
        defer { lock.unlock() }
        guard pendingByTargetTerminalID[request.targetTerminalID]?.id == request.id,
              request.completedResponse == nil,
              request.failure == nil else {
            if let response = request.completedResponse {
                return .completed(response)
            }
            if let failure = request.failure {
                return .failed(failure)
            }
            return .waiting
        }

        guard let responseBody = Self.firstCompleteNonIgnoredResponseBody(
            in: text,
            beginMarker: request.beginMarker,
            endMarker: request.endMarker,
            ignoredMarkerBodyFingerprints: request.ignoredMarkerBodyFingerprints
        ) else {
            return .waiting
        }

        let trimmed = responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
        request.completedResponse = trimmed
        removeLocked(request)
        return .completed(trimmed)
    }

    func state(for request: PendingRequest) -> RequestState {
        lock.lock()
        defer { lock.unlock() }
        if let response = request.completedResponse {
            return .completed(response)
        }
        if let failure = request.failure {
            return .failed(failure)
        }
        return .waiting
    }

    func cancelRequestsInvolving(terminalID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var affected: [PendingRequest] = []
        if let asTarget = pendingByTargetTerminalID[terminalID] {
            affected.append(asTarget)
        }
        if let asCaller = pendingByCallerTerminalID[terminalID],
           !affected.contains(where: { $0.id == asCaller.id }) {
            affected.append(asCaller)
        }
        for request in affected {
            cancelLocked(request)
        }
    }

    @discardableResult
    func cancelRequestForCallerTerminalID(_ callerTerminalID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let request = pendingByCallerTerminalID[callerTerminalID] else {
            return false
        }
        cancelLocked(request)
        return true
    }

    func clearFinishedRequest(_ request: PendingRequest) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(request)
    }

    private func failLocked(_ request: PendingRequest, error: AIRoomMCPError) {
        request.failure = error
        removeLocked(request)
    }

    private func cancelLocked(_ request: PendingRequest) {
        request.failure = .requestCancelled
        request.buffer.removeAll(keepingCapacity: false)
        removeLocked(request)
    }

    private func removeLocked(_ request: PendingRequest) {
        if pendingByTargetTerminalID[request.targetTerminalID]?.id == request.id {
            pendingByTargetTerminalID.removeValue(forKey: request.targetTerminalID)
        }
        if pendingByCallerTerminalID[request.callerTerminalID]?.id == request.id {
            pendingByCallerTerminalID.removeValue(forKey: request.callerTerminalID)
        }
    }

    static func completeMarkerBodies(in buffer: String, beginMarker: String, endMarker: String) -> [String] {
        var bodies: [String] = []
        var remaining = buffer
        while let extracted = extractFirstCompleteResponse(
            from: remaining,
            beginMarker: beginMarker,
            endMarker: endMarker
        ) {
            bodies.append(extracted.body)
            remaining.removeSubrange(..<extracted.endRange.upperBound)
        }
        return bodies
    }

    static func firstCompleteMarkerBody(in buffer: String, beginMarker: String, endMarker: String) -> String? {
        completeMarkerBodies(in: buffer, beginMarker: beginMarker, endMarker: endMarker).first
    }

    private static func firstCompleteNonIgnoredResponseBody(
        in text: String,
        beginMarker: String,
        endMarker: String,
        ignoredMarkerBodyFingerprints: Set<String>
    ) -> String? {
        var remaining = text
        while let extracted = extractFirstCompleteResponse(
            from: remaining,
            beginMarker: beginMarker,
            endMarker: endMarker
        ) {
            if shouldIgnoreMarkerBody(
                extracted.body,
                ignoredMarkerBodyFingerprints: ignoredMarkerBodyFingerprints
            ) {
                remaining.removeSubrange(..<extracted.endRange.upperBound)
                continue
            }
            return extracted.body
        }
        return nil
    }

    private struct ExtractedResponse {
        let body: String
        let endRange: Range<String.Index>
    }

    private static func extractFirstCompleteResponse(
        from buffer: String,
        beginMarker: String,
        endMarker: String
    ) -> ExtractedResponse? {
        var searchStart = buffer.startIndex
        while let endRange = buffer[searchStart...].range(of: endMarker) {
            if let beginRange = buffer[..<endRange.lowerBound].range(of: beginMarker, options: .backwards) {
                return ExtractedResponse(body: String(buffer[beginRange.upperBound..<endRange.lowerBound]), endRange: endRange)
            }
            searchStart = endRange.upperBound
        }
        return nil
    }

    private static func hasCompletedEndMarkerAtBufferTail(_ buffer: String, endMarker: String) -> Bool {
        if buffer.hasSuffix(endMarker) {
            return true
        }

        var index = buffer.endIndex
        while index > buffer.startIndex {
            let previous = buffer.index(before: index)
            let scalar = buffer[previous].unicodeScalars.first
            guard scalar.map({ CharacterSet.whitespacesAndNewlines.contains($0) }) == true else {
                break
            }
            index = previous
        }
        guard index < buffer.endIndex else { return false }
        return buffer[..<index].hasSuffix(endMarker)
    }

    private static func markerBodyFingerprint(_ body: String) -> String {
        String(body.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }).lowercased()
    }

    private static func shouldIgnoreMarkerBody(
        _ body: String,
        ignoredMarkerBodyFingerprints: Set<String>
    ) -> Bool {
        guard !ignoredMarkerBodyFingerprints.isEmpty else { return false }
        let fingerprint = markerBodyFingerprint(body)
        guard !fingerprint.isEmpty else { return false }
        return ignoredMarkerBodyFingerprints.contains(fingerprint)
    }
}

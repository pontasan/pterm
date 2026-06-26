import XCTest
@testable import PtermApp

final class AIRoomMCPResponseCoordinatorTests: XCTestCase {
    func testExtractsFirstCompleteMarkerPairAndTrimsResponse() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let callerID = UUID()
        let targetID = UUID()
        let request = try coordinator.beginRequest(
            callerTerminalID: callerID,
            targetTerminalID: targetID,
            beginMarker: "AI_RESPONSE_BEGIN",
            endMarker: "AI_RESPONSE_END"
        )

        for scalar in "spinner | AI_RESPONSE_BEGIN\n  hello \nAI_RESPONSE_END trailing".unicodeScalars {
            coordinator.appendOutputCodepoint(scalar.value, terminalID: targetID)
        }

        switch coordinator.state(for: request) {
        case .completed(let response):
            XCTAssertEqual(response, "hello")
        case .waiting:
            XCTFail("request should have completed")
        case .failed(let error):
            XCTFail("request failed unexpectedly: \(error)")
        }
    }

    func testSkipsConfiguredInitialEchoMarkerPair() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let callerID = UUID()
        let targetID = UUID()
        let request = try coordinator.beginRequest(
            callerTerminalID: callerID,
            targetTerminalID: targetID,
            beginMarker: "AI_RESPONSE_BEGIN",
            endMarker: "AI_RESPONSE_END",
            ignoredInitialMarkerBody: " and suffix your response with "
        )

        let output = """
        echoed prompt AI_RESPONSE_BEGINandsuffixyourresponsewithAI_RESPONSE_END
        actual response AI_RESPONSE_BEGIN hello from codex AI_RESPONSE_END
        """
        for scalar in output.unicodeScalars {
            coordinator.appendOutputCodepoint(scalar.value, terminalID: targetID)
        }

        switch coordinator.state(for: request) {
        case .completed(let response):
            XCTAssertEqual(response, "hello from codex")
        case .waiting:
            XCTFail("request should have completed after the non-echo marker pair")
        case .failed(let error):
            XCTFail("request failed unexpectedly: \(error)")
        }
    }

    func testPromptEchoMarkerPairAloneDoesNotCompleteRequest() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let targetID = UUID()
        let request = try coordinator.beginRequest(
            callerTerminalID: UUID(),
            targetTerminalID: targetID,
            beginMarker: "AI_RESPONSE_BEGIN",
            endMarker: "AI_RESPONSE_END",
            ignoredInitialMarkerBody: " and suffix your response with "
        )

        for scalar in "AI_RESPONSE_BEGIN  and suffix your response withAI_RESPONSE_END".unicodeScalars {
            let state = coordinator.appendOutputCodepoint(scalar.value, terminalID: targetID)
            if case .completed(let response) = state {
                XCTFail("prompt echo should not complete request: \(response)")
            }
        }
        switch coordinator.state(for: request) {
        case .waiting:
            break
        case .completed(let response):
            XCTFail("prompt echo should not complete request: \(response)")
        case .failed(let error):
            XCTFail("request failed unexpectedly: \(error)")
        }

        for scalar in "\nAI_RESPONSE_BEGIN actual answer AI_RESPONSE_END".unicodeScalars {
            coordinator.appendOutputCodepoint(scalar.value, terminalID: targetID)
        }
        switch coordinator.state(for: request) {
        case .completed(let response):
            XCTAssertEqual(response, "actual answer")
        case .waiting:
            XCTFail("actual response should complete request")
        case .failed(let error):
            XCTFail("request failed unexpectedly: \(error)")
        }
    }

    func testDoesNotSkipFirstMarkerPairWhenItDoesNotMatchConfiguredEcho() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let callerID = UUID()
        let targetID = UUID()
        let request = try coordinator.beginRequest(
            callerTerminalID: callerID,
            targetTerminalID: targetID,
            beginMarker: "AI_RESPONSE_BEGIN",
            endMarker: "AI_RESPONSE_END",
            ignoredInitialMarkerBody: " and suffix your response with "
        )

        for scalar in "AI_RESPONSE_BEGIN real first answer AI_RESPONSE_END".unicodeScalars {
            coordinator.appendOutputCodepoint(scalar.value, terminalID: targetID)
        }

        switch coordinator.state(for: request) {
        case .completed(let response):
            XCTAssertEqual(response, "real first answer")
        case .waiting:
            XCTFail("request should not ignore a different first marker body")
        case .failed(let error):
            XCTFail("request failed unexpectedly: \(error)")
        }
    }

    func testExtractsMarkerBodyFromInstructionPromptForEchoSuppression() {
        let prompt = "Prefix AI_RESPONSE_BEGIN and suffix AI_RESPONSE_END."

        XCTAssertEqual(
            AIRoomMCPResponseCoordinator.firstCompleteMarkerBody(
                in: prompt,
                beginMarker: "AI_RESPONSE_BEGIN",
                endMarker: "AI_RESPONSE_END"
            ),
            " and suffix "
        )
    }

    func testExtractsAllMarkerBodiesFromOutboundPromptForEchoSuppression() {
        let prompt = """
        Prefix AI_RESPONSE_BEGIN and suffix AI_RESPONSE_END.
        Format:
        AI_RESPONSE_BEGIN
        <your response text>
        AI_RESPONSE_END
        """

        XCTAssertEqual(
            AIRoomMCPResponseCoordinator.completeMarkerBodies(
                in: prompt,
                beginMarker: "AI_RESPONSE_BEGIN",
                endMarker: "AI_RESPONSE_END"
            ),
            [
                " and suffix ",
                "\n<your response text>\n"
            ]
        )
    }

    func testIgnoresEveryPromptEchoMarkerPairBeforeActualResponse() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let targetID = UUID()
        let request = try coordinator.beginRequest(
            callerTerminalID: UUID(),
            targetTerminalID: targetID,
            beginMarker: "AI_RESPONSE_BEGIN",
            endMarker: "AI_RESPONSE_END",
            ignoredMarkerBodies: [
                " and suffix your response with ",
                "\n<your response text>\n"
            ]
        )

        let output = """
        echo AI_RESPONSE_BEGIN and suffix your response with AI_RESPONSE_END
        echo format AI_RESPONSE_BEGIN
        <your response text>
        AI_RESPONSE_END
        actual AI_RESPONSE_BEGIN stable answer AI_RESPONSE_END
        """
        for scalar in output.unicodeScalars {
            coordinator.appendOutputCodepoint(scalar.value, terminalID: targetID)
        }

        switch coordinator.state(for: request) {
        case .completed(let response):
            XCTAssertEqual(response, "stable answer")
        case .waiting:
            XCTFail("actual response should complete after all prompt echoes are ignored")
        case .failed(let error):
            XCTFail("request failed unexpectedly: \(error)")
        }
    }

    func testUsesLastBeginBeforeEndWhenEarlierPromptTextContainsStrayBegin() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let targetID = UUID()
        let request = try coordinator.beginRequest(
            callerTerminalID: UUID(),
            targetTerminalID: targetID,
            beginMarker: "AI_RESPONSE_BEGIN",
            endMarker: "AI_RESPONSE_END"
        )

        let output = """
        echoed incomplete instruction AI_RESPONSE_BEGIN without an end yet
        actual AI_RESPONSE_BEGIN real body AI_RESPONSE_END
        """
        for scalar in output.unicodeScalars {
            coordinator.appendOutputCodepoint(scalar.value, terminalID: targetID)
        }

        switch coordinator.state(for: request) {
        case .completed(let response):
            XCTAssertEqual(response, "real body")
        case .waiting:
            XCTFail("actual response should complete")
        case .failed(let error):
            XCTFail("request failed unexpectedly: \(error)")
        }
    }

    func testRequestSpecificMarkersIgnoreOldFixedMarkerResponses() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let targetID = UUID()
        let request = try coordinator.beginRequest(
            callerTerminalID: UUID(),
            targetTerminalID: targetID,
            beginMarker: "AI_RESPONSE_BEGIN__ABC123__",
            endMarker: "AI_RESPONSE_END__ABC123__"
        )

        let oldOutput = """
        AI_RESPONSE_BEGIN
        old answer
        AI_RESPONSE_END
        """
        for scalar in oldOutput.unicodeScalars {
            coordinator.appendOutputCodepoint(scalar.value, terminalID: targetID)
        }
        switch coordinator.state(for: request) {
        case .waiting:
            break
        case .completed(let response):
            XCTFail("old fixed-marker response should not complete request: \(response)")
        case .failed(let error):
            XCTFail("request failed unexpectedly: \(error)")
        }

        let currentOutput = """
        AI_RESPONSE_BEGIN__ABC123__
        current answer
        AI_RESPONSE_END__ABC123__
        """
        for scalar in currentOutput.unicodeScalars {
            coordinator.appendOutputCodepoint(scalar.value, terminalID: targetID)
        }
        switch coordinator.state(for: request) {
        case .completed(let response):
            XCTAssertEqual(response, "current answer")
        case .waiting:
            XCTFail("request-specific response should complete request")
        case .failed(let error):
            XCTFail("request failed unexpectedly: \(error)")
        }
    }

    func testMarkerMatchingRequiresTokenBoundary() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let targetID = UUID()
        let request = try coordinator.beginRequest(
            callerTerminalID: UUID(),
            targetTerminalID: targetID,
            beginMarker: "AI_RESPONSE_BEGIN__1__",
            endMarker: "AI_RESPONSE_END__1__"
        )

        let collidingOutput = """
        AI_RESPONSE_BEGIN__10__
        wrong answer
        AI_RESPONSE_END__10__
        """
        for scalar in collidingOutput.unicodeScalars {
            coordinator.appendOutputCodepoint(scalar.value, terminalID: targetID)
        }
        switch coordinator.state(for: request) {
        case .waiting:
            break
        case .completed(let response):
            XCTFail("prefix-colliding marker should not complete request: \(response)")
        case .failed(let error):
            XCTFail("request failed unexpectedly: \(error)")
        }

        let validOutput = """
        AI_RESPONSE_BEGIN__1__
        right answer
        AI_RESPONSE_END__1__
        """
        for scalar in validOutput.unicodeScalars {
            coordinator.appendOutputCodepoint(scalar.value, terminalID: targetID)
        }
        switch coordinator.state(for: request) {
        case .completed(let response):
            XCTAssertEqual(response, "right answer")
        case .waiting:
            XCTFail("exact marker should complete request")
        case .failed(let error):
            XCTFail("request failed unexpectedly: \(error)")
        }
    }

    func testCompletesFromSnapshotTextWhenMarkersAreAlreadyVisible() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let request = try coordinator.beginRequest(
            callerTerminalID: UUID(),
            targetTerminalID: UUID(),
            beginMarker: "AI_RESPONSE_BEGIN",
            endMarker: "AI_RESPONSE_END",
            ignoredInitialMarkerBody: " and suffix your response with "
        )

        let snapshot = """
        echoed AI_RESPONSE_BEGIN and suffix your response with AI_RESPONSE_END
        visible response AI_RESPONSE_BEGIN
          snapshot body
        AI_RESPONSE_END
        """

        switch coordinator.completeIfResponsePresent(in: snapshot, for: request) {
        case .completed(let response):
            XCTAssertEqual(response, "snapshot body")
        case .waiting:
            XCTFail("request should complete from visible snapshot text")
        case .failed(let error):
            XCTFail("request failed unexpectedly: \(error)")
        }
    }

    func testPromptEchoAndCodexFooterDoNotCompleteBeforeActualMarkedResponse() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let begin = "AI_RESPONSE_BEGIN__1C7CF41263B04E05AB05C2A94EE9BE55__"
        let end = "AI_RESPONSE_END__1C7CF41263B04E05AB05C2A94EE9BE55__"
        let request = try coordinator.beginRequest(
            callerTerminalID: UUID(),
            targetTerminalID: UUID(),
            beginMarker: begin,
            endMarker: end
        )
        let outbound = AppDelegate.aiRoomTargetPrompt(
            protocolConfiguration: AIRoomMCPProtocolConfiguration(
                responseInstructionPrompt: "Use markers.",
                beginMarker: "AI_RESPONSE_BEGIN",
                endMarker: "AI_RESPONSE_END",
                returnPrefixPrompt: "The following response was received."
            ),
            beginMarker: begin,
            endMarker: end,
            message: "軽く雑談しませんか"
        )
        let echoedPromptAndFooter = outbound + "\n›Explain this codebasegpt-5.5 high fast · ~/Developments/workspace/collabo"

        switch coordinator.completeIfResponsePresent(in: echoedPromptAndFooter, for: request) {
        case .waiting:
            break
        case .completed(let response):
            XCTFail("prompt echo and Codex footer should not complete request: \(response)")
        case .failed(let error):
            XCTFail("request failed unexpectedly: \(error)")
        }

        let actualResponse = echoedPromptAndFooter + """

        • \(begin)
          いいですよ。今日はどんな感じですか？
          \(end)
        """
        switch coordinator.completeIfResponsePresent(in: actualResponse, for: request) {
        case .completed(let response):
            XCTAssertEqual(response, "いいですよ。今日はどんな感じですか？")
        case .waiting:
            XCTFail("actual marked response should complete request")
        case .failed(let error):
            XCTFail("request failed unexpectedly: \(error)")
        }
    }

    func testSnapshotResponseFailsWhenUnmarkedTextExceedsBufferLimit() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let request = try coordinator.beginRequest(
            callerTerminalID: UUID(),
            targetTerminalID: UUID(),
            beginMarker: "BEGIN",
            endMarker: "END",
            maxBufferCharacterCount: 8
        )

        switch coordinator.completeIfResponsePresent(in: "123456789", for: request) {
        case .failed(.responseBufferExceeded):
            break
        case let other:
            XCTFail("expected responseBufferExceeded, got \(other)")
        }
    }

    func testSnapshotResponseFailsWhenMarkedBodyExceedsBufferLimit() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let request = try coordinator.beginRequest(
            callerTerminalID: UUID(),
            targetTerminalID: UUID(),
            beginMarker: "BEGIN",
            endMarker: "END",
            maxBufferCharacterCount: 4
        )

        switch coordinator.completeIfResponsePresent(in: "BEGIN 12345 END", for: request) {
        case .failed(.responseBufferExceeded):
            break
        case let other:
            XCTFail("expected responseBufferExceeded, got \(other)")
        }
    }

    func testRejectsConcurrentRequestToSameTargetFromDifferentCaller() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let targetID = UUID()
        _ = try coordinator.beginRequest(
            callerTerminalID: UUID(),
            targetTerminalID: targetID,
            beginMarker: "BEGIN",
            endMarker: "END"
        )

        XCTAssertThrowsError(
            try coordinator.beginRequest(
                callerTerminalID: UUID(),
                targetTerminalID: targetID,
                beginMarker: "BEGIN",
                endMarker: "END"
            )
        ) { error in
            guard case AIRoomMCPError.targetBusy(targetID) = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
        }
    }

    func testStartingNewCallerRequestCancelsPreviousRequest() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let callerID = UUID()
        let firstTargetID = UUID()
        let secondTargetID = UUID()
        let first = try coordinator.beginRequest(
            callerTerminalID: callerID,
            targetTerminalID: firstTargetID,
            beginMarker: "BEGIN",
            endMarker: "END"
        )
        _ = try coordinator.beginRequest(
            callerTerminalID: callerID,
            targetTerminalID: secondTargetID,
            beginMarker: "BEGIN",
            endMarker: "END"
        )

        switch coordinator.state(for: first) {
        case .failed(.requestCancelled):
            break
        default:
            XCTFail("first request should have been cancelled")
        }
    }

    func testCancelRequestForCallerTerminalIDCancelsOnlyThatCallerRequest() throws {
        let coordinator = AIRoomMCPResponseCoordinator()
        let firstCallerID = UUID()
        let firstRequest = try coordinator.beginRequest(
            callerTerminalID: firstCallerID,
            targetTerminalID: UUID(),
            beginMarker: "BEGIN",
            endMarker: "END"
        )
        let secondRequest = try coordinator.beginRequest(
            callerTerminalID: UUID(),
            targetTerminalID: UUID(),
            beginMarker: "BEGIN",
            endMarker: "END"
        )

        XCTAssertTrue(coordinator.cancelRequestForCallerTerminalID(firstCallerID))

        switch coordinator.state(for: firstRequest) {
        case .failed(.requestCancelled):
            break
        default:
            XCTFail("first request should have been cancelled")
        }
        switch coordinator.state(for: secondRequest) {
        case .waiting:
            break
        default:
            XCTFail("second request should still be waiting")
        }
    }
}

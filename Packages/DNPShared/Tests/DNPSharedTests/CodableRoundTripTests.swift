import XCTest
@testable import DNPShared

final class CodableRoundTripTests: XCTestCase {

    func testSessionRoundTrip() throws {
        let s = Session(
            title: "Build feature X",
            projectPath: "/Users/x/Projects/foo",
            projectName: "foo",
            status: .running,
            pendingApprovalCount: 2,
            contextHealth: .moderate
        )
        let data = try DNPCoders.encode(s)
        let restored = try DNPCoders.decode(Session.self, from: data)
        XCTAssertEqual(s, restored)
    }

    func testSessionEventCommandPayloadRoundTrip() throws {
        let cmd = CommandEventPayload(
            command: "npm install",
            workingDirectory: "/tmp/x",
            risk: .medium,
            status: .completed,
            exitCode: 0,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_012),
            durationMs: 12_400,
            outputSummary: "8 packages added"
        )
        let event = SessionEvent(
            sessionId: UUID(),
            sequence: 7,
            type: .commandCompleted,
            severity: .info,
            source: .parser,
            title: "npm install completed",
            summary: "Exit 0",
            payload: .command(cmd)
        )
        let data = try DNPCoders.encode(event)
        let restored = try DNPCoders.decode(SessionEvent.self, from: data)
        XCTAssertEqual(restored, event)
    }

    func testApprovalLifecycleAllStatesEncodeDecode() throws {
        for status in ApprovalStatus.allCases {
            let req = ApprovalRequest(
                sessionId: UUID(),
                actionType: .bashCommand,
                target: "rm -rf node_modules",
                summary: "Clean install",
                risk: .high,
                timeoutAt: Date().addingTimeInterval(300),
                status: status
            )
            let data = try DNPCoders.encode(req)
            let restored = try DNPCoders.decode(ApprovalRequest.self, from: data)
            XCTAssertEqual(restored.status, status)
        }
    }

    func testContextSnapshotRoundTrip() throws {
        let snap = ContextSnapshot(
            sessionId: UUID(),
            usedEstimate: 80_000,
            totalEstimate: 200_000,
            remainingEstimate: 120_000,
            percentRemaining: 0.6,
            health: .healthy,
            confidence: .estimated,
            source: .heuristic,
            warning: nil
        )
        let data = try DNPCoders.encode(snap)
        let restored = try DNPCoders.decode(ContextSnapshot.self, from: data)
        XCTAssertEqual(restored, snap)
    }
}

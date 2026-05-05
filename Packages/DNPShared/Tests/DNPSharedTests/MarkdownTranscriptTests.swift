import XCTest
@testable import DNPShared

final class MarkdownTranscriptTests: XCTestCase {

    func testCommandRendersExpectedSections() {
        let event = SessionEvent(
            sessionId: UUID(), sequence: 1, type: .commandCompleted,
            severity: .info, source: .parser, title: "npm install completed",
            summary: "Exit 0",
            payload: .command(CommandEventPayload(
                command: "npm install",
                workingDirectory: "/tmp",
                risk: .medium,
                status: .completed,
                exitCode: 0,
                durationMs: 12_400,
                outputSummary: "8 packages added"
            ))
        )
        let md = MarkdownTranscript.render(event)
        XCTAssertTrue(md.contains("```sh"))
        XCTAssertTrue(md.contains("npm install"))
        XCTAssertTrue(md.contains("medium"))
        XCTAssertTrue(md.contains("8 packages added"))
        XCTAssertTrue(md.hasSuffix("\n---\n"))
    }

    func testCodeEditRendersDiffAndFile() {
        let event = SessionEvent(
            sessionId: UUID(), sequence: 2, type: .codeEditSummary,
            severity: .info, source: .hookRelay, title: "Edit",
            payload: .codeEdit(CodeEditPayload(
                filePath: "Sources/App/Foo.swift",
                changeKind: .modified,
                linesAdded: 5, linesRemoved: 2,
                summary: "Refactor render path",
                diffPreview: "@@ -1,3 +1,6 @@\n+let x = 1"
            ))
        )
        let md = MarkdownTranscript.render(event)
        XCTAssertTrue(md.contains("Sources/App/Foo.swift"))
        XCTAssertTrue(md.contains("+5"))
        XCTAssertTrue(md.contains("```diff"))
    }
}

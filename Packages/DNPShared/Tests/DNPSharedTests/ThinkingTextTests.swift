import XCTest
@testable import DNPShared

final class ThinkingTextTests: XCTestCase {

    // MARK: - formatElapsedHMS

    func testFormatElapsedSecondsOnly() {
        XCTAssertEqual(ThinkingText.formatElapsedHMS(0), "0s")
        XCTAssertEqual(ThinkingText.formatElapsedHMS(1), "1s")
        XCTAssertEqual(ThinkingText.formatElapsedHMS(59), "59s")
    }

    func testFormatElapsedMinutesAndSeconds() {
        XCTAssertEqual(ThinkingText.formatElapsedHMS(60), "1m")
        XCTAssertEqual(ThinkingText.formatElapsedHMS(125), "2m 5s")
        XCTAssertEqual(ThinkingText.formatElapsedHMS(3599), "59m 59s")
    }

    func testFormatElapsedHoursAndBeyond() {
        XCTAssertEqual(ThinkingText.formatElapsedHMS(3600), "1h")
        XCTAssertEqual(ThinkingText.formatElapsedHMS(3725), "1h 2m 5s")
        XCTAssertEqual(ThinkingText.formatElapsedHMS(7320), "2h 2m")
    }

    // MARK: - formatTokens

    func testFormatTokensBelow1k() {
        XCTAssertEqual(ThinkingText.formatTokens(0), "0")
        XCTAssertEqual(ThinkingText.formatTokens(999), "999")
    }

    func testFormatTokensAbove1k() {
        XCTAssertEqual(ThinkingText.formatTokens(1_000), "1.0k")
        XCTAssertEqual(ThinkingText.formatTokens(3_700), "3.7k")
        XCTAssertEqual(ThinkingText.formatTokens(12_400), "12.4k")
    }

    func testFormatTokensAbove1m() {
        XCTAssertEqual(ThinkingText.formatTokens(1_000_000), "1.0m")
        XCTAssertEqual(ThinkingText.formatTokens(2_500_000), "2.5m")
    }

    // MARK: - extractClaudeVerb

    func testExtractsVerbFromSparkleStatusLine() {
        XCTAssertEqual(
            ThinkingText.extractClaudeVerb(from: "✻ Thinking… (5s · ↓ 1.2k tokens)"),
            "Thinking"
        )
    }

    func testExtractsRotatingVerbsLikePondering() {
        XCTAssertEqual(
            ThinkingText.extractClaudeVerb(from: "✦ Pondering… (12s)"),
            "Pondering"
        )
        XCTAssertEqual(
            ThinkingText.extractClaudeVerb(from: "* Synthesizing... (1m 3s)"),
            "Synthesizing"
        )
    }

    func testExtractFallsBackWhenNoEllipsis() {
        XCTAssertNil(ThinkingText.extractClaudeVerb(from: "✻ Thinking (no ellipsis here)"))
    }

    func testExtractRejectsBlacklistedWords() {
        // "Claude" is blacklisted — would be a verb otherwise.
        XCTAssertNil(ThinkingText.extractClaudeVerb(from: "Claude… something"))
        // "User" is blacklisted.
        XCTAssertNil(ThinkingText.extractClaudeVerb(from: "User… typed something"))
    }

    func testExtractRejectsTooShortOrTooLongWords() {
        XCTAssertNil(ThinkingText.extractClaudeVerb(from: "✦ Hi… too short"))
        XCTAssertNil(ThinkingText.extractClaudeVerb(from: "✦ Antidisestablishmentarianism… way too long"))
    }

    func testExtractRequiresUppercaseFirstChar() {
        XCTAssertNil(ThinkingText.extractClaudeVerb(from: "✦ thinking… lowercase"))
    }

    func testExtractScansMultipleLines() {
        let text = """
        random preamble
        with no ellipsis
        ✻ Crafting… (45s)
        """
        XCTAssertEqual(ThinkingText.extractClaudeVerb(from: text), "Crafting")
    }

    // MARK: - descriptionExcludingVerb

    func testDescriptionDropsVerbLineAndKeepsTip() {
        let input = """
        ✻ Herding… (25s · still thinking with high effort)
          └ Tip: Share Claude Code and earn $10 of extra usage · /passes
        """
        let out = ThinkingText.descriptionExcludingVerb(from: input)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("Tip: Share Claude Code"))
        XCTAssertFalse(out!.contains("Herding"))
    }

    func testDescriptionDropsTodoLines() {
        let input = """
        ✻ Thinking… (10s)
        ▣ Restore session capsule
        ☐ Pending task
        ✓ Completed
        Some other text
        """
        let out = ThinkingText.descriptionExcludingVerb(from: input)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("Some other text"))
        XCTAssertFalse(out!.contains("Restore session capsule"))
        XCTAssertFalse(out!.contains("Pending task"))
        XCTAssertFalse(out!.contains("Completed"))
    }

    func testDescriptionReturnsNilWhenOnlyVerbAndTodos() {
        let input = """
        ✻ Thinking… (10s)
        ▣ Some task
        ☐ Another
        """
        XCTAssertNil(ThinkingText.descriptionExcludingVerb(from: input))
    }

    func testDescriptionReturnsAllTextWhenNoVerbLine() {
        let input = "Just some content with no ellipsis."
        XCTAssertEqual(
            ThinkingText.descriptionExcludingVerb(from: input),
            "Just some content with no ellipsis."
        )
    }

    func testDescriptionTrimsWhitespace() {
        let input = """
        ✻ Thinking… (5s)


           Indented tip
        """
        let out = ThinkingText.descriptionExcludingVerb(from: input)
        XCTAssertEqual(out, "Indented tip")
    }

    // MARK: - isTodoLine

    func testIsTodoLineDetectsAllCheckboxGlyphs() {
        XCTAssertTrue(ThinkingText.isTodoLine("■ Done"))
        XCTAssertTrue(ThinkingText.isTodoLine("□ Pending"))
        XCTAssertTrue(ThinkingText.isTodoLine("▣ In progress"))
        XCTAssertTrue(ThinkingText.isTodoLine("☐ Pending alt"))
        XCTAssertTrue(ThinkingText.isTodoLine("☑ Done alt"))
        XCTAssertTrue(ThinkingText.isTodoLine("✓ Done"))
        XCTAssertTrue(ThinkingText.isTodoLine("✗ Cancelled"))
    }

    func testIsTodoLineToleratesContinuationGlyph() {
        XCTAssertTrue(ThinkingText.isTodoLine("  └ ■ Done with tree connector"))
        XCTAssertTrue(ThinkingText.isTodoLine(" │ ☐ Pending"))
    }

    func testIsTodoLineRejectsRegularText() {
        XCTAssertFalse(ThinkingText.isTodoLine("Tip: Share Claude Code"))
        XCTAssertFalse(ThinkingText.isTodoLine("Just regular sentence."))
        XCTAssertFalse(ThinkingText.isTodoLine(""))
    }
}

import XCTest
@testable import DNPShared

final class ANSIAndRiskTests: XCTestCase {

    func testANSIStripsCSI() {
        let s = "\u{1B}[31mhello\u{1B}[0m world"
        XCTAssertEqual(ANSICleaner.clean(s), "hello world")
    }

    func testANSIStripsOSC() {
        let s = "\u{1B}]0;title\u{07}body"
        XCTAssertEqual(ANSICleaner.clean(s), "body")
    }

    func testCarriageReturnCollapseTakesLastRendering() {
        let s = "loading 1%\rloading 50%\rloading done\nnext line"
        XCTAssertEqual(ANSICleaner.collapseCarriageReturns(s), "loading done\nnext line")
    }

    func testRiskCriticalMatches() {
        XCTAssertEqual(RiskClassifier.risk(forBash: "rm -rf /"), .critical)
        XCTAssertEqual(RiskClassifier.risk(forBash: "shutdown -h now"), .critical)
    }

    func testRiskHighMatches() {
        XCTAssertEqual(RiskClassifier.risk(forBash: "git push --force"), .high)
        XCTAssertEqual(RiskClassifier.risk(forBash: "sudo apt-get install foo"), .high)
    }

    func testRiskLowDefault() {
        XCTAssertEqual(RiskClassifier.risk(forBash: "ls -la"), .low)
        XCTAssertEqual(RiskClassifier.risk(forBash: "cat README.md"), .low)
    }

    func testFileWriteRiskOnEnv() {
        XCTAssertEqual(RiskClassifier.risk(forFileWrite: "/Users/x/.env"), .critical)
        XCTAssertEqual(RiskClassifier.risk(forFileWrite: "/tmp/Podfile"), .high)
        XCTAssertEqual(RiskClassifier.risk(forFileWrite: "/tmp/foo.txt"), .low)
    }

    func testContextEstimatorWarnsOnLow() {
        let est = ContextEstimator(bytesPerToken: 4, totalTokenBudget: 100_000)
        let snap = est.snapshot(sessionId: UUID(), transcriptBytes: 380_000, eventCount: 200)
        XCTAssertEqual(snap.health, .critical)
        XCTAssertEqual(snap.warning, .sessionEndingSoon)
    }
}

import XCTest
@testable import DNPShared

final class PathUtilitiesTests: XCTestCase {

    // Drops a single trailing slash so `/foo/bar/` and `/foo/bar`
    // collapse to the same comparison key. This was the actual root
    // cause of the cross-project session leakage we hit in production.
    func testTrailingSlashCollapsesToSameKey() {
        XCTAssertEqual(
            PathUtilities.normalizedProjectPath("/Users/me/proj/"),
            PathUtilities.normalizedProjectPath("/Users/me/proj")
        )
    }

    // Resolves `.` segments via URL.standardizedFileURL.
    func testDotSegmentsResolved() {
        XCTAssertEqual(
            PathUtilities.normalizedProjectPath("/Users/me/./proj"),
            "/Users/me/proj"
        )
    }

    // Resolves `..` segments via URL.standardizedFileURL.
    func testDoubleDotSegmentsResolved() {
        XCTAssertEqual(
            PathUtilities.normalizedProjectPath("/Users/me/x/../proj"),
            "/Users/me/proj"
        )
    }

    // Tilde-expansion happens before standardisation so two callers
    // that disagree on whether `~` was already expanded still match.
    func testTildeExpansionMatchesAbsoluteForm() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            PathUtilities.normalizedProjectPath("~/Workspace"),
            PathUtilities.normalizedProjectPath("\(home)/Workspace")
        )
    }

    // Root-only paths keep their single slash; the trim-trailing
    // step has a guard for length > 1.
    func testRootIsPreserved() {
        XCTAssertEqual(PathUtilities.normalizedProjectPath("/"), "/")
    }

    // The convenience equality wrapper composes correctly across
    // the surface forms above.
    func testProjectPathsMatchHandlesAllSurfaceForms() {
        XCTAssertTrue(PathUtilities.projectPathsMatch(
            "/Users/me/proj/",
            "/Users/me/./proj"
        ))
        XCTAssertFalse(PathUtilities.projectPathsMatch(
            "/Users/me/proj",
            "/Users/me/other"
        ))
    }
}

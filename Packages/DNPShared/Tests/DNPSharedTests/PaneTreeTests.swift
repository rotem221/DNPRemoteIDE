import XCTest
@testable import DNPShared

final class PaneTreeTests: XCTestCase {

    // MARK: - Inspection

    func testLeafCountAndLeavesForSingleLeaf() {
        let id = UUID()
        let tree = PaneTree.leaf(id)
        XCTAssertEqual(tree.leafCount, 1)
        XCTAssertEqual(tree.leaves, [id])
        XCTAssertEqual(tree.firstLeaf, id)
    }

    func testLeafCountAndOrderForSplit() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree: PaneTree = .split(
            direction: .horizontal,
            leading: .leaf(a),
            trailing: .split(direction: .vertical,
                             leading: .leaf(b),
                             trailing: .leaf(c),
                             fraction: 0.5),
            fraction: 0.5
        )
        XCTAssertEqual(tree.leafCount, 3)
        XCTAssertEqual(tree.leaves, [a, b, c])  // depth-first leading-first
        XCTAssertEqual(tree.firstLeaf, a)
        XCTAssertTrue(tree.contains(b))
        XCTAssertFalse(tree.contains(UUID()))
    }

    // MARK: - replacing

    func testReplacingLeafWithSplit() {
        let a = UUID(), b = UUID(), c = UUID()
        let original: PaneTree = .leaf(a)
        let replaced = original.replacing(a, with: .split(
            direction: .horizontal,
            leading: .leaf(a),
            trailing: .leaf(b),
            fraction: 0.5
        ))
        XCTAssertEqual(replaced.leafCount, 2)
        XCTAssertEqual(replaced.leaves, [a, b])
        // Replacing a non-existent leaf is a no-op.
        XCTAssertEqual(replaced, replaced.replacing(c, with: .leaf(c)))
    }

    // MARK: - removing

    func testRemovingLeafCollapsesParent() {
        let a = UUID(), b = UUID()
        let tree: PaneTree = .split(direction: .horizontal,
                                    leading: .leaf(a),
                                    trailing: .leaf(b),
                                    fraction: 0.5)
        // Removing the trailing leaf collapses the parent to the leading leaf.
        XCTAssertEqual(tree.removing(b), .leaf(a))
        // Removing the leading leaf collapses the parent to the trailing leaf.
        XCTAssertEqual(tree.removing(a), .leaf(b))
    }

    func testRemovingOnlyLeafReturnsNil() {
        let id = UUID()
        XCTAssertNil(PaneTree.leaf(id).removing(id))
    }

    func testRemovingMissingIdReturnsSelf() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree: PaneTree = .split(direction: .horizontal,
                                    leading: .leaf(a),
                                    trailing: .leaf(b),
                                    fraction: 0.5)
        XCTAssertEqual(tree.removing(c), tree)
    }

    // MARK: - swapping

    func testSwappingTwoLeaves() {
        let a = UUID(), b = UUID()
        let original: PaneTree = .split(direction: .horizontal,
                                        leading: .leaf(a),
                                        trailing: .leaf(b),
                                        fraction: 0.5)
        let swapped = original.swapping(a, b)
        XCTAssertEqual(swapped.leaves, [b, a])
    }

    func testSwappingLeavesNotInTreeIsNoOp() {
        let a = UUID(), b = UUID()
        let original: PaneTree = .leaf(a)
        XCTAssertEqual(original.swapping(b, UUID()), original)
    }

    // MARK: - pruning

    func testPruningRemovesDeadLeaves() {
        let live = UUID(), dead = UUID()
        let tree: PaneTree = .split(direction: .horizontal,
                                    leading: .leaf(live),
                                    trailing: .leaf(dead),
                                    fraction: 0.5)
        let kept = tree.pruning { $0 == live }
        XCTAssertEqual(kept, .leaf(live))
    }

    func testPruningEverythingReturnsNil() {
        let tree: PaneTree = .split(direction: .horizontal,
                                    leading: .leaf(UUID()),
                                    trailing: .leaf(UUID()),
                                    fraction: 0.5)
        XCTAssertNil(tree.pruning { _ in false })
    }

    // MARK: - settingFraction

    func testSettingFractionTargetsExactSplit() {
        let a = UUID(), b = UUID(), c = UUID()
        // Two same-axis splits stacked: outer holds [a | inner], inner holds [b | c].
        let inner: PaneTree = .split(direction: .horizontal,
                                     leading: .leaf(b),
                                     trailing: .leaf(c),
                                     fraction: 0.5)
        let outer: PaneTree = .split(direction: .horizontal,
                                     leading: .leaf(a),
                                     trailing: inner,
                                     fraction: 0.5)
        // Drag the inner divider — only the inner fraction should change.
        let mutated = outer.settingFraction(
            0.7,
            forSplitWithLeading: .leaf(b),
            trailing: .leaf(c)
        )
        if case .split(_, .leaf, .split(_, _, _, let innerFraction), let outerFraction) = mutated {
            XCTAssertEqual(innerFraction, 0.7)
            XCTAssertEqual(outerFraction, 0.5)  // outer unchanged
        } else {
            XCTFail("Mutated tree didn't match expected shape")
        }
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let tree: PaneTree = .split(
            direction: .vertical,
            leading: .leaf(UUID()),
            trailing: .split(direction: .horizontal,
                             leading: .leaf(UUID()),
                             trailing: .leaf(UUID()),
                             fraction: 0.4),
            fraction: 0.6
        )
        let data = try DNPCoders.encode(tree)
        let decoded = try DNPCoders.decode(PaneTree.self, from: data)
        XCTAssertEqual(decoded, tree)
    }
}

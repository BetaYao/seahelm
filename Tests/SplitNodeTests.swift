import XCTest
@testable import seahelm

final class SplitNodeTests: XCTestCase {

    func testSingleLeaf() {
        let node = SplitNode.leaf(id: "a", stationId: "s1", paneSessionKey: "seahelm-repo-main")
        XCTAssertEqual(node.leafCount, 1)
        XCTAssertEqual(node.allLeaves.count, 1)
        XCTAssertEqual(node.allLeaves.first?.id, "a")
    }

    func testSplitNodeLeafCount() {
        let left = SplitNode.leaf(id: "a", stationId: "s1", paneSessionKey: "seahelm-repo-main")
        let right = SplitNode.leaf(id: "b", stationId: "s2", paneSessionKey: "seahelm-repo-main-1")
        let split = SplitNode.split(id: "s", axis: .horizontal, ratio: 0.5, first: left, second: right)
        XCTAssertEqual(split.leafCount, 2)
        XCTAssertEqual(split.allLeaves.count, 2)
    }

    func testFindLeafById() {
        let left = SplitNode.leaf(id: "a", stationId: "s1", paneSessionKey: "seahelm-repo-main")
        let right = SplitNode.leaf(id: "b", stationId: "s2", paneSessionKey: "seahelm-repo-main-1")
        let split = SplitNode.split(id: "s", axis: .horizontal, ratio: 0.5, first: left, second: right)
        XCTAssertNotNil(split.findLeaf(id: "a"))
        XCTAssertNotNil(split.findLeaf(id: "b"))
        XCTAssertNil(split.findLeaf(id: "c"))
    }

    func testCodableRoundTrip_Leaf() throws {
        let node = CodableSplitNode.leaf(paneSessionKey: "seahelm-repo-main", title: "Fix the bug")
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(CodableSplitNode.self, from: data)
        if case .leaf(let name, let title) = decoded {
            XCTAssertEqual(name, "seahelm-repo-main")
            XCTAssertEqual(title, "Fix the bug")
        } else {
            XCTFail("Expected leaf")
        }
    }

    func testCodableLeaf_DecodesLegacyWithoutTitle() throws {
        // Older configs have no `title` key — must still decode (title = nil).
        let json = Data(#"{"type":"leaf","sessionName":"seahelm-repo-main"}"#.utf8)
        let decoded = try JSONDecoder().decode(CodableSplitNode.self, from: json)
        guard case .leaf(let name, let title) = decoded else { return XCTFail("Expected leaf") }
        XCTAssertEqual(name, "seahelm-repo-main")
        XCTAssertNil(title)
    }

    func testCodableRoundTrip_Split() throws {
        let node = CodableSplitNode.split(
            axis: "horizontal",
            ratio: 0.6,
            first: .leaf(paneSessionKey: "seahelm-repo-main", title: nil),
            second: .leaf(paneSessionKey: "seahelm-repo-main-1", title: nil)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(node)
        let decoded = try JSONDecoder().decode(CodableSplitNode.self, from: data)
        if case .split(let axis, let ratio, _, _) = decoded {
            XCTAssertEqual(axis, "horizontal")
            XCTAssertEqual(ratio, 0.6)
        } else {
            XCTFail("Expected split")
        }
    }

    func testNextPaneIndex_NoPanes() {
        let node = SplitNode.leaf(id: "a", stationId: "s1", paneSessionKey: "seahelm-repo-main")
        XCTAssertEqual(node.nextPaneIndex(baseName: "seahelm-repo-main"), 1)
    }

    func testNextPaneIndex_WithExistingPanes() {
        let left = SplitNode.leaf(id: "a", stationId: "s1", paneSessionKey: "seahelm-repo-main")
        let right = SplitNode.leaf(id: "b", stationId: "s2", paneSessionKey: "seahelm-repo-main-1")
        let split = SplitNode.split(id: "s", axis: .horizontal, ratio: 0.5, first: left, second: right)
        XCTAssertEqual(split.nextPaneIndex(baseName: "seahelm-repo-main"), 2)
    }
}

final class SplitTreeTests: XCTestCase {

    func testInitialState() {
        let tree = SplitTree(worktreePath: "/repo/main", rootLeafId: "a", stationId: "s1", paneSessionKey: "seahelm-repo-main")
        XCTAssertEqual(tree.focusedId, "a")
        XCTAssertEqual(tree.leafCount, 1)
        XCTAssertEqual(tree.allStationIds.count, 1)
    }

    func testSplitFocusedLeaf() {
        let tree = SplitTree(worktreePath: "/repo/main", rootLeafId: "a", stationId: "s1", paneSessionKey: "seahelm-repo-main")
        let newLeafId = tree.splitFocusedLeaf(axis: .horizontal, newLeafId: "b", newStationId: "s2", newSessionName: "seahelm-repo-main-1").leafId
        XCTAssertEqual(newLeafId, "b")
        XCTAssertEqual(tree.focusedId, "b")
        XCTAssertEqual(tree.leafCount, 2)
    }

    func testCloseLeaf_PromotesSibling() {
        let tree = SplitTree(worktreePath: "/repo/main", rootLeafId: "a", stationId: "s1", paneSessionKey: "seahelm-repo-main")
        _ = tree.splitFocusedLeaf(axis: .horizontal, newLeafId: "b", newStationId: "s2", newSessionName: "seahelm-repo-main-1")
        let closed = tree.closeFocusedLeaf()
        XCTAssertEqual(closed?.id, "b")
        XCTAssertEqual(tree.focusedId, "a")
        XCTAssertEqual(tree.leafCount, 1)
    }

    func testCloseLeaf_ThreePanes_PromotesSibling() {
        // A | (B | C) — split A first, then split B to create C
        let tree = SplitTree(worktreePath: "/repo/main", rootLeafId: "a", stationId: "s1", paneSessionKey: "seahelm-repo-main")
        _ = tree.splitFocusedLeaf(axis: .horizontal, newLeafId: "b", newStationId: "s2", newSessionName: "seahelm-repo-main-1")
        // Focus is on B, split again to get C
        _ = tree.splitFocusedLeaf(axis: .horizontal, newLeafId: "c", newStationId: "s3", newSessionName: "seahelm-repo-main-2")
        XCTAssertEqual(tree.leafCount, 3)
        // Focus is on C, close it — should leave A | B
        let closed = tree.closeFocusedLeaf()
        XCTAssertEqual(closed?.id, "c")
        XCTAssertEqual(tree.leafCount, 2)
        // Now focus B, close it — should leave just A
        tree.focusedId = "b"
        let closed2 = tree.closeFocusedLeaf()
        XCTAssertEqual(closed2?.id, "b")
        XCTAssertEqual(tree.leafCount, 1)
        XCTAssertEqual(tree.focusedId, "a")
    }

    func testCloseLeaf_LastPaneCannotClose() {
        let tree = SplitTree(worktreePath: "/repo/main", rootLeafId: "a", stationId: "s1", paneSessionKey: "seahelm-repo-main")
        let closed = tree.closeFocusedLeaf()
        XCTAssertNil(closed)
        XCTAssertEqual(tree.leafCount, 1)
    }

    func testNextSessionName() {
        let tree = SplitTree(worktreePath: "/repo/main", rootLeafId: "a", stationId: "s1", paneSessionKey: "seahelm-repo-main")
        XCTAssertEqual(tree.nextSessionName(), "seahelm-repo-main-1")
        _ = tree.splitFocusedLeaf(axis: .horizontal, newLeafId: "b", newStationId: "s2", newSessionName: "seahelm-repo-main-1")
        XCTAssertEqual(tree.nextSessionName(), "seahelm-repo-main-2")
    }

    func testAllSurfaceIds() {
        let tree = SplitTree(worktreePath: "/repo/main", rootLeafId: "a", stationId: "s1", paneSessionKey: "seahelm-repo-main")
        _ = tree.splitFocusedLeaf(axis: .horizontal, newLeafId: "b", newStationId: "s2", newSessionName: "seahelm-repo-main-1")
        let ids = tree.allStationIds
        XCTAssertTrue(ids.contains("s1"))
        XCTAssertTrue(ids.contains("s2"))
    }
}

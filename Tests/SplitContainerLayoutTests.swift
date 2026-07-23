import XCTest
@testable import seahelm

final class SplitContainerLayoutTests: XCTestCase {

    func testComputeFrames_SingleLeaf() {
        let frames = SplitContainerView.computeFrames(
            node: .leaf(id: "a", stationId: "s1", paneSessionKey: "test"),
            in: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames["a"], CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    func testComputeFrames_HorizontalSplit() {
        let node = SplitNode.split(
            id: "s", axis: .horizontal, ratio: 0.5,
            first: .leaf(id: "a", stationId: "s1", paneSessionKey: "t1"),
            second: .leaf(id: "b", stationId: "s2", paneSessionKey: "t2")
        )
        let frames = SplitContainerView.computeFrames(
            node: node,
            in: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertEqual(frames.count, 2)
        let a = frames["a"]!
        let b = frames["b"]!
        XCTAssertEqual(a.origin.x, 0)
        XCTAssertTrue(a.width > 390 && a.width < 405)
        XCTAssertTrue(b.origin.x > 395)
        XCTAssertEqual(a.height, 600)
        XCTAssertEqual(b.height, 600)
    }

    func testComputeFrames_VerticalSplit() {
        let node = SplitNode.split(
            id: "s", axis: .vertical, ratio: 0.5,
            first: .leaf(id: "a", stationId: "s1", paneSessionKey: "t1"),
            second: .leaf(id: "b", stationId: "s2", paneSessionKey: "t2")
        )
        let frames = SplitContainerView.computeFrames(
            node: node,
            in: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let a = frames["a"]!
        let b = frames["b"]!
        XCTAssertEqual(a.width, 800)
        XCTAssertEqual(b.width, 800)
        XCTAssertTrue(a.height > 290 && a.height < 305)
    }
}

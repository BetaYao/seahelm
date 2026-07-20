import XCTest
@testable import seahelm

final class LayoutNodeTests: XCTestCase {

    func testPaneRoundTrip() {
        let node = LayoutNode.pane(label: "seahelm-repo-main", command: "claude", agent: "Claude Code", cwd: "/wt")
        let back = LayoutNode(dict: node.dict)
        XCTAssertEqual(back, node)
    }

    func testSplitRoundTrip() {
        let node = LayoutNode.split(direction: "right", ratio: 0.6,
            first: .pane(label: "a", command: "claude", agent: nil, cwd: nil),
            second: .pane(label: "b", command: "npm run dev", agent: nil, cwd: nil))
        XCTAssertEqual(LayoutNode(dict: node.dict), node)
    }

    func testPaneCount() {
        let node = LayoutNode.split(direction: "down", ratio: 0.5,
            first: .pane(label: nil, command: nil, agent: nil, cwd: nil),
            second: .split(direction: "right", ratio: 0.5,
                first: .pane(label: nil, command: nil, agent: nil, cwd: nil),
                second: .pane(label: nil, command: nil, agent: nil, cwd: nil)))
        XCTAssertEqual(node.paneCount, 3)
    }

    func testInvalidDicts() {
        XCTAssertNil(LayoutNode(dict: ["type": "bogus"]))
        XCTAssertNil(LayoutNode(dict: ["type": "split", "direction": "sideways",
                                       "first": ["type": "pane"], "second": ["type": "pane"]]))
        XCTAssertNil(LayoutNode(dict: ["type": "split", "direction": "right",
                                       "first": ["type": "pane"]]))  // missing second
    }

    func testDefaultRatio() {
        let d: [String: Any] = ["type": "split", "direction": "right",
                                "first": ["type": "pane"], "second": ["type": "pane"]]
        guard case .split(_, let ratio, _, _)? = LayoutNode(dict: d) else { return XCTFail() }
        XCTAssertEqual(ratio, 0.5)
    }
}

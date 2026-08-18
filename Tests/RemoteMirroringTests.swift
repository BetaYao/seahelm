import XCTest
@testable import seahelm

/// A data source that only knows how to mirror a window — everything else falls
/// through to the protocol-extension defaults, which is the point: adding the
/// mirroring surface must not force existing conformers to implement it.
private final class MirrorDataSource: ControlDataSource {
    var layouts: [String: [String: Any]]?
    var groupsByMode: [String: [[String: Any]]] = [:]
    private(set) var requestedModes: [String] = []

    func snapshotPanes() -> [PaneSnapshot] { [] }
    func snapshotPanes(includingMemory: Bool) -> [PaneSnapshot] { [] }
    func readPane(paneId: String, source: String, lines: Int) -> String? { nil }
    func ingestHook(json: [String: Any]) -> String? { nil }
    func sendKeys(paneId: String, keys: [String]) -> Bool { false }

    func liveLayouts() -> [String: [String: Any]]? { layouts }
    func worktreeGroups(mode: String) -> [[String: Any]]? {
        requestedModes.append(mode)
        return groupsByMode[mode]
    }
}

final class RemoteMirroringTests: XCTestCase {

    // MARK: - Wire shape

    func testLeafCarriesTheKeyVTOpenTakes() {
        let node = CodableSplitNode.leaf(paneSessionKey: "seahelm-repo-main", title: "claude")
        let d = node.dict
        XCTAssertEqual(d["type"] as? String, "leaf")
        XCTAssertEqual(d["pane_session_key"] as? String, "seahelm-repo-main")
        XCTAssertEqual(d["title"] as? String, "claude")
    }

    func testEmptyTitleIsOmittedRatherThanShippedBlank() {
        let d = CodableSplitNode.leaf(paneSessionKey: "k", title: "").dict
        XCTAssertNil(d["title"])
    }

    func testNestedSplitSerializesBothAxes() {
        let tree = CodableSplitNode.split(
            axis: "horizontal", ratio: 0.6,
            first: .leaf(paneSessionKey: "a", title: nil),
            second: .split(axis: "vertical", ratio: 0.25,
                           first: .leaf(paneSessionKey: "b", title: nil),
                           second: .leaf(paneSessionKey: "c", title: nil)))
        let d = tree.dict
        XCTAssertEqual(d["axis"] as? String, "horizontal")
        XCTAssertEqual(d["ratio"] as? Double, 0.6)
        let second = d["second"] as? [String: Any]
        XCTAssertEqual(second?["axis"] as? String, "vertical")
        let inner = second?["first"] as? [String: Any]
        XCTAssertEqual(inner?["pane_session_key"] as? String, "b")
    }

    // MARK: - layout.live

    func testLayoutLiveReturnsEveryWorktree() {
        let ds = MirrorDataSource()
        ds.layouts = ["/wt/a": ["root": ["type": "leaf", "pane_session_key": "a"]]]
        guard case .ok(let d) = ControlRouter(dataSource: ds)
            .handle(method: "layout.live", params: [:]) else { return XCTFail() }
        XCTAssertEqual((d["layouts"] as? [String: Any])?.count, 1)
    }

    func testLayoutLiveNarrowsToOneWorktree() {
        let ds = MirrorDataSource()
        ds.layouts = [
            "/wt/a": ["root": ["type": "leaf", "pane_session_key": "a"]],
            "/wt/b": ["root": ["type": "leaf", "pane_session_key": "b"]],
        ]
        let router = ControlRouter(dataSource: ds)
        guard case .ok(let d) = router
            .handle(method: "layout.live", params: ["worktree_path": "/wt/b"]) else { return XCTFail() }
        XCTAssertEqual((d["root"] as? [String: Any])?["pane_session_key"] as? String, "b")

        guard case .error(let code, _) = router
            .handle(method: "layout.live", params: ["worktree_path": "/wt/zzz"]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.notFound)
    }

    func testLayoutLiveWithoutAWindowIsNotFound() {
        guard case .error(let code, _) = ControlRouter(dataSource: MirrorDataSource())
            .handle(method: "layout.live", params: [:]) else { return XCTFail() }
        XCTAssertEqual(code, ControlError.notFound)
    }

    // MARK: - fleet.groups

    func testFleetGroupsDefaultsToRepository() {
        let ds = MirrorDataSource()
        ds.groupsByMode["repository"] = [["id": "repository:seahelm", "title": "seahelm", "items": []]]
        guard case .ok(let d) = ControlRouter(dataSource: ds)
            .handle(method: "fleet.groups", params: [:]) else { return XCTFail() }
        XCTAssertEqual(d["mode"] as? String, "repository")
        XCTAssertEqual((d["groups"] as? [[String: Any]])?.first?["title"] as? String, "seahelm")
        XCTAssertEqual(ds.requestedModes, ["repository"])
    }

    func testFleetGroupsPassesTheRequestedMode() {
        let ds = MirrorDataSource()
        ds.groupsByMode["status"] = [["id": "status:Waiting", "title": "Needs input", "items": []]]
        guard case .ok(let d) = ControlRouter(dataSource: ds)
            .handle(method: "fleet.groups", params: ["mode": "status"]) else { return XCTFail() }
        XCTAssertEqual(d["mode"] as? String, "status")
        XCTAssertEqual(ds.requestedModes, ["status"])
    }

    // MARK: - Mode vocabulary

    func testWireModesMapOntoTheDashboardsOwnModes() {
        XCTAssertEqual(WorktreeGroupingMode(wire: "repository"), .repository)
        XCTAssertEqual(WorktreeGroupingMode(wire: "status"), .status)
        XCTAssertEqual(WorktreeGroupingMode(wire: "activity"), .activityTime)
        XCTAssertEqual(WorktreeGroupingMode(wire: "time"), .activityTime)
        // Anything unrecognised lands on the mode the desktop also starts in.
        XCTAssertEqual(WorktreeGroupingMode(wire: "nonsense"), .repository)
        for mode in WorktreeGroupingMode.allCases {
            XCTAssertEqual(WorktreeGroupingMode(wire: mode.wire), mode, "round trip for \(mode)")
        }
    }

    func testGroupSerializationCarriesStatusAndItems() {
        let item = WorktreeGroupingItem(
            id: "w1", path: "/wt/a", repository: "seahelm", status: .waiting,
            lastActivityAt: Date(timeIntervalSince1970: 1000), isMainWorktree: true,
            creationDate: Date(timeIntervalSince1970: 0))
        let group = WorktreeGroup(id: .status(.waiting), title: "Needs input", status: .waiting, items: [item])
        let d = group.dict
        XCTAssertEqual(d["id"] as? String, "status:Waiting")
        XCTAssertEqual(d["status"] as? String, "Waiting")
        let items = d["items"] as? [[String: Any]]
        XCTAssertEqual(items?.first?["worktree_path"] as? String, "/wt/a")
        XCTAssertEqual(items?.first?["status"] as? String, "Waiting")
        XCTAssertEqual(items?.first?["last_activity_at"] as? Double, 1000)
        XCTAssertEqual(items?.first?["is_main_worktree"] as? Bool, true)
    }
}

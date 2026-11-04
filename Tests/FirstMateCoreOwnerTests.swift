import XCTest
@testable import seahelm

/// First Mate run by seahelm-core (`autopilot_owner: "core"`): the app only
/// mirrors its cards and reads its audit log.
final class FirstMateCoreOwnerTests: XCTestCase {
    private func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "fm-core-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func testOwnerKeyRoundTrips() throws {
        let decoded = try JSONDecoder().decode(Config.self, from: Data(#"{"autopilot_owner": "core"}"#.utf8))
        XCTAssertTrue(decoded.autopilotRunsInCore)
        let plain = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertFalse(plain.autopilotRunsInCore)
        let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(again.autopilotOwner, "core")
    }

    func testCoreCardsAreMirroredAndRetired() {
        let dir = tempDir()
        let coordinator = AutopilotCoordinator(auditPath: dir + "/audit.jsonl", ledgerPath: dir + "/state.json")
        var approvals: [(String, String)] = []
        var proposals: [(String, String, [String])] = []
        var closed: [String] = []
        coordinator.onRequestApproval = { approvals.append(($0, $1)) }
        coordinator.onRequestProposal = { proposals.append(($0, $1, $2)) }
        coordinator.onApprovalClosed = { closed.append($0) }

        let approval: [String: Any] = ["card": "autopilot-1", "kind": "approval", "message": "First Mate asks: Delete worktree x", "options": ["Approve", "Reject"]]
        let proposal: [String: Any] = ["card": "proposal-2", "kind": "proposal", "message": "First Mate suggests: Start one", "options": ["Start #88", "Not now"]]
        let both: [String: Any] = ["enabled": true, "cards": [approval, proposal]]
        coordinator.applyRemote(both)
        coordinator.applyRemote(both)
        XCTAssertEqual(approvals.map(\.0), ["autopilot-1"])
        XCTAssertEqual(approvals.first?.1, "Delete worktree x")
        XCTAssertEqual(proposals.first?.1, "Start one")
        XCTAssertEqual(proposals.first?.2, ["Start #88", "Not now"])
        XCTAssertEqual(coordinator.state.pendingApprovals, 2)

        coordinator.applyRemote(["enabled": true, "cards": [proposal]])
        XCTAssertEqual(closed, ["autopilot-1"])
        XCTAssertEqual(coordinator.state.pendingApprovals, 1)
    }

    func testAuditIsReadInCompleteLinesFromWhereItLeftOff() throws {
        let path = tempDir() + "/audit.jsonl"
        let line1 = #"{"at":"2026-11-03T09:30:00Z","kind":"event","text":"ci.failed · x"}"#
        let line2 = #"{"at":"2026-11-03T09:31:00Z","kind":"action","action":"message_pane","level":"auto","text":"Tell #3: fix"}"#
        try (line1 + "\n" + String(line2.prefix(20))).write(toFile: path, atomically: true, encoding: .utf8)
        let (first, offset) = AutopilotCoordinator.readAudit(path: path, from: 0)
        XCTAssertEqual(first.map(\.text), ["ci.failed · x"])
        try (line1 + "\n" + line2 + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let (second, end) = AutopilotCoordinator.readAudit(path: path, from: offset)
        XCTAssertEqual(second.map(\.kind), [.action])
        XCTAssertEqual(AutopilotCoordinator.readAudit(path: path, from: end).0.count, 0)
        // Replaced by a shorter file: from the top.
        try (line1 + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(AutopilotCoordinator.readAudit(path: path, from: end).0.count, 1)
    }

    func testCoreReplies() {
        let ok = CoreSocketClient.parse(Data(#"{"jsonrpc":"2.0","id":1,"result":{"enabled":true}}"#.utf8 + [0x0A]))
        XCTAssertEqual((try? ok.get())?["enabled"] as? Bool, true)
        let refused = CoreSocketClient.parse(Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32040,"message":"First Mate is paused"}}"#.utf8))
        if case .failure(.rpc(let code, let message)) = refused {
            XCTAssertEqual(code, -32040)
            XCTAssertEqual(message, "First Mate is paused")
        } else {
            XCTFail("expected an rpc error")
        }
        XCTAssertEqual(CoreSocketClient.call("core.ping", path: "/nonexistent/core.sock").failureValue, .unreachable)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}

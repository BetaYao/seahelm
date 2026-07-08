import XCTest
@testable import seahelm

final class AgentSessionRefTests: XCTestCase {
    private let uuid = "f637907b-a9b7-429a-941c-b407fe2487ee"

    func testValidClaudeRef() {
        let ref = AgentSessionRef(agent: "claude", sessionId: uuid)
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.resumeCommandLine(), "claude --resume \(uuid)")
    }

    func testFromSourceMapping() {
        XCTAssertEqual(AgentSessionRef(source: "claude-code", sessionId: uuid)?.agent, "claude")
        XCTAssertEqual(AgentSessionRef(source: "claude", sessionId: uuid)?.agent, "claude")
        // Unsupported agents are rejected in Step 1.
        XCTAssertNil(AgentSessionRef(source: "codex", sessionId: uuid))
        XCTAssertNil(AgentSessionRef(source: "bogus", sessionId: uuid))
    }

    func testRejectsUnsupportedAgent() {
        XCTAssertNil(AgentSessionRef(agent: "codex", sessionId: uuid))
    }

    func testIdsAreDataNotShellText() {
        // A malicious id can never be constructed, so it can never reach a shell.
        XCTAssertNil(AgentSessionRef(agent: "claude", sessionId: "abc; rm -rf /"))
        XCTAssertNil(AgentSessionRef(agent: "claude", sessionId: "$(whoami)"))
        XCTAssertNil(AgentSessionRef(agent: "claude", sessionId: "a b"))
        XCTAssertNil(AgentSessionRef(agent: "claude", sessionId: ""))
        XCTAssertNil(AgentSessionRef(agent: "claude", sessionId: "id\nwith\nnewline"))
    }

    func testDecodeRejectsGarbage() throws {
        let bad = #"{"agent":"claude","session_id":"a; rm -rf /"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(AgentSessionRef.self, from: bad))
        let unsupported = #"{"agent":"codex","session_id":"\#(uuid)"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(AgentSessionRef.self, from: unsupported))
    }

    func testRoundTrip() throws {
        let ref = AgentSessionRef(agent: "claude", sessionId: uuid)!
        let data = try JSONEncoder().encode(ref)
        let back = try JSONDecoder().decode(AgentSessionRef.self, from: data)
        XCTAssertEqual(ref, back)
    }

    func testConfigRoundTripCarriesAgentSessions() throws {
        var config = Config()
        config.agentSessions["amux-repo-main"] = AgentSessionRef(agent: "claude", sessionId: uuid)
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(back.agentSessions["amux-repo-main"]?.sessionId, uuid)
    }

    func testConfigBackwardCompatMissingKey() throws {
        // Old config without agent_sessions decodes to an empty map.
        let json = #"{"workspace_paths":[]}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(config.agentSessions, [:])
    }
}

import XCTest
@testable import seahelm

final class MessageConfigManifestTests: XCTestCase {
    func testManifestDecodesOptionalMessageBlock() throws {
        let json = """
        {
          "id": "cursor",
          "message": {
            "assistant_from": "stop_last_assistant_message",
            "user_fields": ["prompt", "message"],
            "tool_aliases": {"run_terminal_cmd": "Shell"},
            "coalesce_tools": true,
            "screen_fallback": false
          }
        }
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(AgentManifest.self, from: json)
        XCTAssertEqual(m.id, "cursor")
        let msg = try XCTUnwrap(m.message)
        XCTAssertEqual(msg.assistantFrom, "stop_last_assistant_message")
        XCTAssertEqual(msg.userFields, ["prompt", "message"])
        XCTAssertEqual(msg.toolAliases["run_terminal_cmd"], "Shell")
        XCTAssertTrue(msg.coalesceTools)
        XCTAssertFalse(msg.screenFallback)
    }

    func testManifestWithoutMessageUsesNil() throws {
        let json = #"{"id":"claude"}"#.data(using: .utf8)!
        let m = try JSONDecoder().decode(AgentManifest.self, from: json)
        XCTAssertNil(m.message)
    }

    func testMessageEventDictShape() {
        let ev = MessageEvent(
            seq: 7,
            paneId: "p1",
            paneSessionKey: "seahelm-x",
            kind: .tool,
            ts: Date(timeIntervalSince1970: 100),
            tool: "Read",
            detail: "a.swift",
            isError: false,
            count: 1
        )
        let d = ev.dict
        XCTAssertEqual(d["seq"] as? UInt64, 7)
        XCTAssertEqual(d["kind"] as? String, "tool")
        XCTAssertEqual(d["tool"] as? String, "Read")
        XCTAssertEqual(d["detail"] as? String, "a.swift")
        XCTAssertEqual(d["pane_id"] as? String, "p1")
    }
}

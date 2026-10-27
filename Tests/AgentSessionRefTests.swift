import XCTest
@testable import seahelm

final class AgentSessionRefTests: XCTestCase {
    private let uuid = "f637907b-a9b7-429a-941c-b407fe2487ee"

    func testValidClaudeRef() {
        let ref = AgentSessionRef(agent: "claude", sessionId: uuid)
        XCTAssertNotNil(ref)
        // Every token is single-quoted so the value is inert as shell text.
        XCTAssertEqual(ref?.resumeCommandLine(), "'claude' '--resume' '\(uuid)'")
    }

    func testFromSourceMapping() {
        XCTAssertEqual(AgentSessionRef(source: "claude-code", sessionId: uuid)?.agent, "claude")
        XCTAssertEqual(AgentSessionRef(source: "claude", sessionId: uuid)?.agent, "claude")
        XCTAssertEqual(AgentSessionRef(source: "codex", sessionId: uuid)?.agent, "codex")
        // Unsupported agents are rejected.
        XCTAssertNil(AgentSessionRef(source: "bogus", sessionId: uuid))
    }

    func testCodexResumeCommand() {
        let ref = AgentSessionRef(agent: "codex", sessionId: uuid)
        XCTAssertEqual(ref?.resumeCommandLine(), "'codex' 'resume' '\(uuid)'")
    }

    func testRejectsUnsupportedAgent() {
        XCTAssertNil(AgentSessionRef(agent: "gemini", sessionId: uuid))
    }

    // MARK: - Expanded agent table (mirrors herdr's resume planner)

    func testExpandedAgentArgvRows() {
        XCTAssertEqual(AgentSessionRef(agent: "copilot", sessionId: uuid)?.resumeCommandLine(),
                       "'copilot' '--resume=\(uuid)'")
        XCTAssertEqual(AgentSessionRef(agent: "droid", sessionId: uuid)?.resumeCommandLine(),
                       "'droid' '--resume' '\(uuid)'")
        XCTAssertEqual(AgentSessionRef(agent: "opencode", sessionId: uuid)?.resumeCommandLine(),
                       "'opencode' '--session' '\(uuid)'")
        XCTAssertEqual(AgentSessionRef(agent: "kimi", sessionId: uuid)?.resumeCommandLine(),
                       "'kimi' '--session' '\(uuid)'")
        // Cursor Agent's CLI entrypoint is `agent` (not the IDE's `cursor` shim).
        XCTAssertEqual(AgentSessionRef(agent: "cursor", sessionId: uuid)?.resumeCommandLine(),
                       "'agent' '--resume' '\(uuid)'")
    }

    // MARK: - Path kind

    func testPathKindResume() {
        let path = "/Users/dev/.pi/sessions/abc.json"
        let ref = AgentSessionRef(agent: "pi", kind: .path, sessionId: path)
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.kind, .path)
        XCTAssertEqual(ref?.resumeCommandLine(), "'pi' '--session' '\(path)'")
    }

    func testPathIsShellQuotedEvenWithSpaces() {
        // A path with a space must not split into two argv tokens.
        let path = "/Users/dev/My Projects/omp/session.json"
        let ref = AgentSessionRef(agent: "omp", kind: .path, sessionId: path)
        XCTAssertEqual(ref?.resumeCommandLine(), "'omp' '--resume=\(path)'")
    }

    func testPathKindRejectsRelativeAndControlChars() {
        XCTAssertNil(AgentSessionRef(agent: "pi", kind: .path, sessionId: "relative/path.json"))
        XCTAssertNil(AgentSessionRef(agent: "pi", kind: .path, sessionId: "/path/with\nnewline"))
        XCTAssertNil(AgentSessionRef(agent: "pi", kind: .path, sessionId: ""))
    }

    func testAgentsWithoutPathKindRejectPath() {
        // claude/codex resume by id only.
        XCTAssertNil(AgentSessionRef(agent: "claude", kind: .path, sessionId: "/some/path.jsonl"))
        XCTAssertNil(AgentSessionRef(agent: "codex", kind: .path, sessionId: "/some/path"))
    }

    func testSourcePrefersPathForPathAgents() {
        let path = "/Users/dev/.pi/sessions/abc.json"
        // pi prefers path when both are present.
        let ref = AgentSessionRef(source: "pi", sessionId: uuid, sessionPath: path)
        XCTAssertEqual(ref?.kind, .path)
        XCTAssertEqual(ref?.sessionId, path)
        // Falls back to id when no path is available.
        let idRef = AgentSessionRef(source: "pi", sessionId: uuid, sessionPath: nil)
        XCTAssertEqual(idRef?.kind, .id)
    }

    func testSourceIgnoresPathForIdAgents() {
        // claude uses id even when a transcript path is offered.
        let ref = AgentSessionRef(source: "claude", sessionId: uuid,
                                  sessionPath: "/Users/dev/.claude/projects/x/\(uuid).jsonl")
        XCTAssertEqual(ref?.kind, .id)
        XCTAssertEqual(ref?.sessionId, uuid)
    }

    func testDecodeBackwardCompatMissingKindDefaultsToId() throws {
        // A config written before `kind` existed decodes as an id ref.
        let json = #"{"agent":"claude","session_id":"\#(uuid)"}"#.data(using: .utf8)!
        let ref = try JSONDecoder().decode(AgentSessionRef.self, from: json)
        XCTAssertEqual(ref.kind, .id)
        XCTAssertEqual(ref.sessionId, uuid)
    }

    func testPathRefRoundTrips() throws {
        let ref = AgentSessionRef(agent: "pi", kind: .path, sessionId: "/x/y.json")!
        let back = try JSONDecoder().decode(AgentSessionRef.self, from: JSONEncoder().encode(ref))
        XCTAssertEqual(ref, back)
        XCTAssertEqual(back.kind, .path)
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
        let unsupported = #"{"agent":"gemini","session_id":"\#(uuid)"}"#.data(using: .utf8)!
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
        config.agentSessions["seahelm-repo-main"] = AgentSessionRef(agent: "claude", sessionId: uuid)
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(back.agentSessions["seahelm-repo-main"]?.sessionId, uuid)
    }

    func testConfigBackwardCompatMissingKey() throws {
        // Old config without agent_sessions decodes to an empty map.
        let json = #"{"workspace_paths":[]}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(config.agentSessions, [:])
    }

    func testClaudeForkCommandQuotesEveryToken() {
        let ref = AgentSessionRef(agent: "claude", sessionId: uuid)!
        XCTAssertTrue(ref.supportsFork)
        XCTAssertEqual(ref.forkCommandLine(),
                       "'claude' '--resume' '\(uuid)' '--fork-session'")
        XCTAssertEqual(ref.forkCommandLine(extraArgs: ["--dangerously-skip-permissions"]),
                       "'claude' '--resume' '\(uuid)' '--fork-session' '--dangerously-skip-permissions'")
    }

    /// The prompt is read from a file, not spelled out: the command line is
    /// typed into a tty that cuts input past 1024 bytes.
    func testForkPromptIsReadFromItsFileAsOneArgument() throws {
        let ref = AgentSessionRef(agent: "claude", sessionId: uuid)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let prompt = String(repeating: "carry on, it's `here` $HOME. ", count: 60)
        let file = try XCTUnwrap(PaneFork.writePromptFile(prompt, directory: dir))
        let line = try XCTUnwrap(ref.forkCommandLine(promptFile: file))
        XCTAssertLessThan(line.utf8.count, 150 + file.utf8.count)

        // Swap the agent for printf to see the argv the shell hands it.
        let probe = line.replacingOccurrences(of: "'claude' '--resume' '\(uuid)' '--fork-session'",
                                              with: "printf '%s\\n'")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", probe]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(printed, prompt + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    }

    func testAgentsWithoutForkReturnNil() {
        let codex = AgentSessionRef(agent: "codex", sessionId: "abc-123")!
        XCTAssertFalse(codex.supportsFork)
        XCTAssertNil(codex.forkCommandLine())
    }
}

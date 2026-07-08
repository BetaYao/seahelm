import Foundation

/// A persisted reference to an agent's native session, used to relaunch the
/// agent with its own resume flag after a backend session is recreated (zmx
/// recovery, reboot, or restore into a missing session).
///
/// The session id is treated as *data*, never as shell text. Validation is
/// enforced at the type boundary so a malformed id can never be constructed and
/// therefore can never reach a shell command line. See `resumeCommandLine`.
struct AgentSessionRef: Codable, Equatable {
    /// Normalized agent name, e.g. "claude". Maps from a `WebhookEvent.source`
    /// via `init(source:sessionId:)`.
    let agent: String
    /// The agent's own session identifier (for Claude, the transcript stem /
    /// `--resume` argument).
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case agent
        case sessionId = "session_id"
    }

    /// Failable init that rejects anything we won't resume or can't safely pass
    /// to a shell. Currently only Claude is supported; extend `resumeArgv` and
    /// the agent whitelist as more agents are wired.
    init?(agent: String, sessionId: String) {
        guard Self.isSupportedAgent(agent), Self.isValidSessionId(sessionId) else { return nil }
        self.agent = agent
        self.sessionId = sessionId
    }

    /// Build from a `WebhookEvent.source`. Returns nil for unsupported agents.
    init?(source: String, sessionId: String) {
        guard let agent = Self.agent(forSource: source) else { return nil }
        self.init(agent: agent, sessionId: sessionId)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let agent = try c.decode(String.self, forKey: .agent)
        let sessionId = try c.decode(String.self, forKey: .sessionId)
        // Reject persisted garbage on decode too, so a hand-edited config can't
        // inject via a stale ref.
        guard Self.isSupportedAgent(agent), Self.isValidSessionId(sessionId) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionId, in: c,
                debugDescription: "invalid AgentSessionRef(agent=\(agent))"
            )
        }
        self.agent = agent
        self.sessionId = sessionId
    }

    /// Map a `WebhookEvent.source` to a normalized agent name we know how to
    /// resume. Step 1 supports Claude only.
    static func agent(forSource source: String) -> String? {
        switch source {
        case "claude-code", "claude": return "claude"
        default: return nil
        }
    }

    static func isSupportedAgent(_ agent: String) -> Bool {
        resumeArgv(agent: agent, sessionId: "x") != nil
    }

    /// Session ids we accept. Claude ids are UUIDs; restrict to the UUID
    /// alphabet so the value is inert as shell text regardless of quoting.
    static func isValidSessionId(_ id: String) -> Bool {
        !id.isEmpty
            && id.count <= 128
            && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// The argv the agent should be relaunched with. Table-driven, one entry per
    /// supported agent (mirrors herdr's resume planner).
    static func resumeArgv(agent: String, sessionId: String) -> [String]? {
        switch agent {
        case "claude": return ["claude", "--resume", sessionId]
        default: return nil
        }
    }

    /// A shell command line safe to interpolate into the backend launch string.
    /// Safe because `sessionId` is validated to the UUID alphabet and the agent
    /// token is a fixed literal.
    func resumeCommandLine() -> String? {
        guard let argv = Self.resumeArgv(agent: agent, sessionId: sessionId) else { return nil }
        return argv.joined(separator: " ")
    }
}

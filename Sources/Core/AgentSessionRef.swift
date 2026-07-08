import Foundation

/// A persisted reference to an agent's native session, used to relaunch the
/// agent with its own resume flag after a backend session is recreated (zmx
/// recovery, reboot, or restore into a missing session).
///
/// The reference value (a session id or a session file path) is treated as
/// *data*, never as trusted shell text. Two defenses apply:
///   1. Validation at the type boundary (`isValid`) rejects control characters
///      and — for ids — anything outside a shell-inert alphabet.
///   2. `resumeCommandLine()` shell-quotes every argv token before it is
///      interpolated into the backend launch string, so even a path containing
///      spaces or shell metacharacters is inert.
///
/// The design mirrors herdr's resume planner (`src/agent_resume.rs`): a
/// table-driven per-agent argv builder, with a `kind` distinguishing agents
/// that resume by session id from those that resume by transcript path.
struct AgentSessionRef: Codable, Equatable {
    /// How the agent locates the session to resume.
    enum Kind: String, Codable, Equatable {
        /// An opaque session identifier (e.g. Claude's transcript stem / UUID).
        case id
        /// An absolute filesystem path to the session/transcript file. Some
        /// agents (pi, omp) resume by path more reliably than by id.
        case path
    }

    /// Normalized agent name, e.g. "claude". Maps from a `WebhookEvent.source`
    /// via `agent(forSource:)`.
    let agent: String
    /// Whether `sessionId` holds an id or a filesystem path.
    let kind: Kind
    /// The agent's own session reference. Despite the name it holds an id when
    /// `kind == .id` and an absolute path when `kind == .path`. The JSON key
    /// stays `session_id` for backward compatibility with configs written
    /// before `kind` existed.
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case agent
        case kind
        case sessionId = "session_id"
    }

    /// Failable init that rejects anything we won't resume or can't safely pass
    /// to a shell. Extend `resumeArgv` and `agent(forSource:)` as more agents
    /// are wired.
    init?(agent: String, kind: Kind = .id, sessionId: String) {
        guard Self.isValid(kind: kind, value: sessionId),
              Self.resumeArgv(agent: agent, kind: kind, value: sessionId) != nil else { return nil }
        self.agent = agent
        self.kind = kind
        self.sessionId = sessionId
    }

    /// Build from a `WebhookEvent.source`, preferring a session path over an id
    /// for agents that resume by path (mirrors herdr's `session_ref_from_report`).
    /// Returns nil for unsupported agents or when no usable reference is present.
    init?(source: String, sessionId: String?, sessionPath: String? = nil) {
        guard let agent = Self.agent(forSource: source) else { return nil }
        if Self.prefersPath(agent), let path = sessionPath,
           let ref = AgentSessionRef(agent: agent, kind: .path, sessionId: path) {
            self = ref
            return
        }
        guard let id = sessionId,
              let ref = AgentSessionRef(agent: agent, kind: .id, sessionId: id) else { return nil }
        self = ref
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let agent = try c.decode(String.self, forKey: .agent)
        // Configs written before `kind` existed carry only an id.
        let kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .id
        let sessionId = try c.decode(String.self, forKey: .sessionId)
        // Reject persisted garbage on decode too, so a hand-edited config can't
        // inject via a stale ref.
        guard Self.isValid(kind: kind, value: sessionId),
              Self.resumeArgv(agent: agent, kind: kind, value: sessionId) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionId, in: c,
                debugDescription: "invalid AgentSessionRef(agent=\(agent), kind=\(kind))"
            )
        }
        self.agent = agent
        self.kind = kind
        self.sessionId = sessionId
    }

    /// Map a `WebhookEvent.source` to a normalized agent name we know how to
    /// resume. Only claude/codex are emitted by our native hooks today; the
    /// remainder are reachable via the generic webhook protocol (a payload with
    /// an explicit `source`), and each already has an argv row below.
    static func agent(forSource source: String) -> String? {
        switch source {
        case "claude-code", "claude": return "claude"
        case "codex": return "codex"
        case "copilot": return "copilot"
        case "devin": return "devin"
        case "droid": return "droid"
        case "kimi": return "kimi"
        case "mastracode": return "mastracode"
        case "pi": return "pi"
        case "omp": return "omp"
        case "hermes": return "hermes"
        case "opencode": return "opencode"
        case "qodercli": return "qodercli"
        case "kilo": return "kilo"
        case "cursor", "cursor-agent": return "cursor"
        default: return nil
        }
    }

    /// Agents that resume more reliably from a session path than an id.
    static func prefersPath(_ agent: String) -> Bool {
        agent == "pi" || agent == "omp"
    }

    /// Validate a reference value for a given kind.
    static func isValid(kind: Kind, value: String) -> Bool {
        switch kind {
        case .id: return isValidSessionId(value)
        case .path: return isValidSessionPath(value)
        }
    }

    /// Session ids we accept. Claude ids are UUIDs; Codex ids can be broader.
    /// Restrict to a shell-safe alphabet (alphanumerics, `-`, `_`) so the value
    /// is inert as shell text regardless of quoting — no spaces, quotes, `$`,
    /// `;`, or control characters can ever appear.
    static func isValidSessionId(_ id: String) -> Bool {
        !id.isEmpty
            && id.count <= 128
            && id.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    /// Session paths we accept: a non-empty, control-character-free absolute
    /// path. Metacharacters (spaces, `$`, quotes) are allowed because
    /// `resumeCommandLine()` shell-quotes the value; control characters are not,
    /// since they cannot be safely round-tripped. Mirrors herdr's
    /// `valid_session_path`.
    static func isValidSessionPath(_ path: String) -> Bool {
        !path.isEmpty
            && path.count <= 4096
            && path.hasPrefix("/")
            && !path.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// The argv the agent should be relaunched with. Table-driven, one entry per
    /// supported (agent, kind) pair (mirrors herdr's resume planner). Returns
    /// nil when the agent doesn't support the given kind.
    static func resumeArgv(agent: String, kind: Kind, value: String) -> [String]? {
        switch (agent, kind) {
        case ("claude", .id): return ["claude", "--resume", value]
        case ("codex", .id): return ["codex", "resume", value]
        case ("copilot", .id): return ["copilot", "--resume=\(value)"]
        case ("devin", .id): return ["devin", "--resume", value]
        case ("droid", .id): return ["droid", "--resume", value]
        case ("kimi", .id): return ["kimi", "--session", value]
        case ("mastracode", .id): return ["mastracode", "--thread", value]
        // pi / omp accept either an id or a path.
        case ("pi", .id), ("pi", .path): return ["pi", "--session", value]
        case ("omp", .id), ("omp", .path): return ["omp", "--resume=\(value)"]
        case ("hermes", .id): return ["hermes", "--resume", value]
        case ("opencode", .id): return ["opencode", "--session", value]
        case ("qodercli", .id): return ["qodercli", "--resume", value]
        case ("kilo", .id): return ["kilo", "--session", value]
        case ("cursor", .id): return ["cursor-agent", "--resume", value]
        default: return nil
        }
    }

    /// A shell command line safe to interpolate into the backend launch string.
    /// Every token is single-quoted, so the value — id or path — is inert
    /// regardless of the characters it contains.
    func resumeCommandLine() -> String? {
        guard let argv = Self.resumeArgv(agent: agent, kind: kind, value: sessionId) else { return nil }
        return argv.map(ShellEscape.singleQuote).joined(separator: " ")
    }
}

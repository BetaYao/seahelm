import Foundation

// MARK: - Control API protocol (herdr-style JSON-RPC over a Unix socket)
//
// Wire format: newline-delimited JSON, one request per line.
//   request:  {"id": "r1", "method": "pane.read", "params": {...}}
//   response: {"id": "r1", "result": {...}}   or   {"id": "r1", "error": {"code", "message"}}
//
// This file is the pure, transport-free core: request parsing, the method
// router, and the ControlDataSource seam the app implements. ControlSocketServer
// owns the Unix socket; tests drive ControlRouter with a fake data source.

/// A pane's identity + state for `session.snapshot` / `pane.list`.
struct PaneSnapshot {
    let paneId: String        // stable terminal ID (durable, unlike herdr's compact ids)
    let worktreePath: String
    let branch: String
    let project: String
    let agentType: String
    let status: String
    let lastMessage: String

    var dict: [String: Any] {
        ["pane_id": paneId, "worktree_path": worktreePath, "branch": branch,
         "project": project, "agent_type": agentType, "status": status,
         "last_message": lastMessage]
    }
}

/// The app-side data the control API reads/drives. Kept minimal for Phase 1
/// (read-only); write methods (send_text/split) extend this later.
protocol ControlDataSource: AnyObject {
    func snapshotPanes() -> [PaneSnapshot]
    /// Read a pane's terminal text. `source`: visible | recent | detection.
    func readPane(paneId: String, source: String, lines: Int) -> String?
    /// Feed an inbound hook/suggest payload (same shape as the HTTP webhook body)
    /// into the shared event sink. Returns an optional block-body string (used by
    /// blocking Stop hooks); nil for fire-and-forget events like suggest.
    func ingestHook(json: [String: Any]) -> String?

    // MARK: Phase 2 — write channel + wait (default no-ops so read-only
    // conformers/fakes keep compiling).

    /// Type `text` into a pane; append a real Return key when `enter`. Returns
    /// false if the pane is unknown.
    func sendText(paneId: String, text: String, enter: Bool) -> Bool
    /// Deliver a sequence of named keys/combos (enter, esc, tab, arrows,
    /// ctrl+<letter>, single chars) to a pane. False if the pane is unknown.
    func sendKeys(paneId: String, keys: [String]) -> Bool
    /// Current rolled-up status of a pane (SailorStatus raw value), or nil if unknown.
    func paneStatus(paneId: String) -> String?
    /// Split a pane (nil = the focused pane) in the given direction
    /// (right|left|down|up). Returns the new pane's id, or nil if the pane can't
    /// be split here. `focus` false = don't steal the caller's cursor.
    func splitPane(paneId: String?, direction: String, focus: Bool) -> String?
}

extension ControlDataSource {
    func sendText(paneId: String, text: String, enter: Bool) -> Bool { false }
    func sendKeys(paneId: String, keys: [String]) -> Bool { false }
    func paneStatus(paneId: String) -> String? { nil }
    func splitPane(paneId: String?, direction: String, focus: Bool) -> String? { nil }
}

/// Pure mapping of named keys/combos to the raw bytes they deliver to the PTY.
/// "enter"/"return" are excluded (callers send a real Return key event, which
/// agent TUIs treat as submit rather than a literal newline).
enum ControlKeys {
    static func isEnter(_ name: String) -> Bool {
        let k = name.lowercased(); return k == "enter" || k == "return"
    }

    static func bytes(for name: String) -> String? {
        switch name.lowercased() {
        case "enter", "return":   return nil
        case "esc", "escape":     return "\u{1b}"
        case "tab":               return "\t"
        case "space":             return " "
        case "backspace", "bs":   return "\u{7f}"
        case "up":                return "\u{1b}[A"
        case "down":              return "\u{1b}[B"
        case "right":             return "\u{1b}[C"
        case "left":              return "\u{1b}[D"
        default:
            let k = name.lowercased()
            // ctrl+<letter> → the corresponding control byte (ctrl+c → 0x03).
            if k.hasPrefix("ctrl+"), k.count == 6, let c = k.last,
               let a = c.asciiValue, a >= 97, a <= 122 {
                return String(UnicodeScalar(a - 96))
            }
            // A single literal character is sent verbatim.
            return name.count == 1 ? name : nil
        }
    }

    /// Normalize a `keys` param that may arrive as a string or an array.
    static func parseKeys(_ raw: Any?) -> [String] {
        if let arr = raw as? [String] { return arr }
        if let s = raw as? String { return s.isEmpty ? [] : [s] }
        return []
    }
}

enum ControlResult {
    case ok([String: Any])
    case error(code: Int, message: String)
}

enum ControlError {
    static let parse = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let notFound = -32004
}

/// Pure request router. No IO, no singletons — the data source is injected.
final class ControlRouter {
    // Strong: the data source is a stateless bridge to singletons, no cycle.
    var dataSource: ControlDataSource?

    init(dataSource: ControlDataSource? = nil) {
        self.dataSource = dataSource
    }

    func handle(method: String, params: [String: Any]) -> ControlResult {
        switch method {
        case "ping":
            return .ok(["pong": true])

        case "session.snapshot", "pane.list":
            let panes = dataSource?.snapshotPanes() ?? []
            return .ok(["panes": panes.map(\.dict)])

        case "pane.read":
            guard let paneId = params["pane_id"] as? String, !paneId.isEmpty else {
                return .error(code: ControlError.invalidParams, message: "pane_id required")
            }
            let source = params["source"] as? String ?? "visible"
            let lines = (params["lines"] as? Int) ?? 100
            guard let text = dataSource?.readPane(paneId: paneId, source: source, lines: lines) else {
                return .error(code: ControlError.notFound, message: "pane not found: \(paneId)")
            }
            return .ok(["text": text])

        case "hook":
            // Raw webhook-shaped payload (parity with the HTTP webhook body).
            // The optional block body (a Stop-hook `{"decision":"block",...}` JSON)
            // is returned base64-encoded so the shell hook script can extract it
            // with a trivial, quote-safe regex and `base64 -d` it to stdout.
            let block = dataSource?.ingestHook(json: params)
            if let block, let b64 = block.data(using: .utf8)?.base64EncodedString() {
                return .ok(["block_b64": b64])
            }
            return .ok([:])

        case "pane.send_text", "pane.run":
            guard let paneId = params["pane_id"] as? String, !paneId.isEmpty else {
                return .error(code: ControlError.invalidParams, message: "pane_id required")
            }
            let text = (params["text"] as? String) ?? (params["command"] as? String) ?? ""
            // pane.run always submits; pane.send_text submits only if asked.
            let enter = method == "pane.run" ? true : (params["enter"] as? Bool ?? false)
            guard dataSource?.sendText(paneId: paneId, text: text, enter: enter) == true else {
                return .error(code: ControlError.notFound, message: "pane not found: \(paneId)")
            }
            return .ok(["sent": true])

        case "pane.send_keys":
            guard let paneId = params["pane_id"] as? String, !paneId.isEmpty else {
                return .error(code: ControlError.invalidParams, message: "pane_id required")
            }
            let keys = ControlKeys.parseKeys(params["keys"])
            guard !keys.isEmpty else {
                return .error(code: ControlError.invalidParams, message: "keys required")
            }
            guard dataSource?.sendKeys(paneId: paneId, keys: keys) == true else {
                return .error(code: ControlError.notFound, message: "pane not found: \(paneId)")
            }
            return .ok(["sent": true])

        case "pane.split":
            let paneId = (params["pane_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let direction = (params["direction"] as? String)?.lowercased() ?? "right"
            guard ["right", "left", "down", "up"].contains(direction) else {
                return .error(code: ControlError.invalidParams, message: "direction must be right|left|down|up")
            }
            let focus = params["focus"] as? Bool ?? true
            guard let newId = dataSource?.splitPane(paneId: paneId, direction: direction, focus: focus) else {
                return .error(code: ControlError.notFound, message: "cannot split pane")
            }
            return .ok(["pane_id": newId])

        case "pane.wait_for_output", "wait.output":
            return waitForOutput(params: params)

        case "pane.wait_agent_status", "wait.agent_status":
            return waitAgentStatus(params: params)

        case "suggest":
            guard let options = params["options"] as? [String], !options.isEmpty else {
                return .error(code: ControlError.invalidParams, message: "options required")
            }
            var payload: [String: Any] = [
                "source": "seahelm-suggest",
                "event": "suggest",
                "cwd": params["cwd"] as? String ?? "",
                "session_id": params["pane_id"] as? String ?? "cli",
                "data": ["options": options],
            ]
            if let paneId = params["pane_id"] as? String { payload["pane_id"] = paneId }
            _ = dataSource?.ingestHook(json: payload)
            return .ok(["accepted": true])

        default:
            return .error(code: ControlError.methodNotFound, message: "unknown method: \(method)")
        }
    }

    // MARK: - Wait primitives
    //
    // These block the calling (per-connection) thread, polling the data source
    // until the condition holds or the timeout elapses. Each socket connection
    // runs on its own thread, so blocking one wait does not stall others.

    private static let waitPollInterval: TimeInterval = 0.15
    private static let defaultWaitTimeoutMs = 30_000
    private static let maxWaitTimeoutMs = 600_000

    private func timeout(from params: [String: Any]) -> TimeInterval {
        let ms = min((params["timeout_ms"] as? Int) ?? Self.defaultWaitTimeoutMs, Self.maxWaitTimeoutMs)
        return TimeInterval(max(0, ms)) / 1000
    }

    private func waitForOutput(params: [String: Any]) -> ControlResult {
        guard let paneId = params["pane_id"] as? String, !paneId.isEmpty else {
            return .error(code: ControlError.invalidParams, message: "pane_id required")
        }
        guard let match = params["match"] as? String, !match.isEmpty else {
            return .error(code: ControlError.invalidParams, message: "match required")
        }
        let source = params["source"] as? String ?? "recent"
        let useRegex = params["regex"] as? Bool ?? false
        let re = useRegex ? try? NSRegularExpression(pattern: match) : nil
        if useRegex && re == nil {
            return .error(code: ControlError.invalidParams, message: "invalid regex: \(match)")
        }
        let deadline = Date().addingTimeInterval(timeout(from: params))
        repeat {
            guard let text = dataSource?.readPane(paneId: paneId, source: source, lines: 2000) else {
                return .error(code: ControlError.notFound, message: "pane not found: \(paneId)")
            }
            if Self.matches(text: text, match: match, regex: re) {
                return .ok(["matched": true])
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: Self.waitPollInterval)
        } while Date() < deadline
        return .ok(["matched": false, "timed_out": true])
    }

    private func waitAgentStatus(params: [String: Any]) -> ControlResult {
        guard let paneId = params["pane_id"] as? String, !paneId.isEmpty else {
            return .error(code: ControlError.invalidParams, message: "pane_id required")
        }
        guard let want = (params["status"] as? String)?.lowercased(), !want.isEmpty else {
            return .error(code: ControlError.invalidParams, message: "status required")
        }
        let deadline = Date().addingTimeInterval(timeout(from: params))
        repeat {
            guard let status = dataSource?.paneStatus(paneId: paneId)?.lowercased() else {
                return .error(code: ControlError.notFound, message: "pane not found: \(paneId)")
            }
            if Self.statusMatches(status, want: want) {
                return .ok(["matched": true, "status": status])
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: Self.waitPollInterval)
        } while Date() < deadline
        return .ok(["matched": false, "timed_out": true])
    }

    static func matches(text: String, match: String, regex: NSRegularExpression?) -> Bool {
        if let regex {
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        return text.contains(match)
    }

    /// `done` is an alias for a finished pane (idle or exited); otherwise compare
    /// the SailorStatus raw value case-insensitively.
    static func statusMatches(_ status: String, want: String) -> Bool {
        if want == "done" { return status == "idle" || status == "exited" }
        return status == want
    }

    // MARK: - Framing (pure, testable)

    /// Parse one request line. Returns (id, method, params) or a framed error
    /// response JSON string if the line is malformed.
    static func parseRequest(_ line: String) -> (id: String, method: String, params: [String: Any])? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String else {
            return nil
        }
        let id = (obj["id"] as? String) ?? (obj["id"].map { "\($0)" } ?? "")
        let params = obj["params"] as? [String: Any] ?? [:]
        return (id, method, params)
    }

    /// Serialize a result into a single response line (newline-terminated).
    static func encodeResponse(id: String, result: ControlResult) -> String {
        var obj: [String: Any] = ["id": id]
        switch result {
        case .ok(let r):
            obj["result"] = r
        case .error(let code, let message):
            obj["error"] = ["code": code, "message": message]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"id\":\"\(id)\",\"error\":{\"code\":\(ControlError.parse),\"message\":\"encode failed\"}}\n"
        }
        return s + "\n"
    }

    static func encodeParseError() -> String {
        "{\"id\":\"\",\"error\":{\"code\":\(ControlError.parse),\"message\":\"invalid JSON\"}}\n"
    }
}

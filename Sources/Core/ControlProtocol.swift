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

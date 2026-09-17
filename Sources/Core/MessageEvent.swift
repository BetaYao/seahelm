import Foundation

enum MessageKind: String, Equatable {
    case user, assistant, tool, status, decision, notice
    /// What the agent narrates while it works — Claude's visible thinking, a Codex
    /// reasoning summary. Shown apart from what it says.
    case thinking
}

struct MessageEvent: Equatable {
    var seq: UInt64
    var paneId: String
    var paneSessionKey: String
    var kind: MessageKind
    var ts: Date
    var text: String? = nil
    var tool: String? = nil
    var detail: String? = nil
    var isError: Bool? = nil
    var status: String? = nil
    var oldStatus: String? = nil
    var count: Int = 1

    var dict: [String: Any] {
        var d: [String: Any] = [
            "seq": seq,
            "pane_id": paneId,
            "pane_session_key": paneSessionKey,
            "kind": kind.rawValue,
            "ts": ts.timeIntervalSince1970,
        ]
        if let text { d["text"] = text }
        if let tool { d["tool"] = tool }
        if let detail { d["detail"] = detail }
        if let isError { d["is_error"] = isError }
        if let status { d["status"] = status }
        if let oldStatus { d["old_status"] = oldStatus }
        if count > 1 { d["count"] = count }
        return d
    }

    /// The pane this event belongs to across restarts. The zmx session name
    /// survives a relaunch; the station id is only a fallback for panes without one.
    var ringKey: String { paneSessionKey.isEmpty ? paneId : paneSessionKey }
}

extension MessageEvent {
    /// Inverse of `dict`, for events read back from disk.
    init?(dict d: [String: Any]) {
        guard let seq = (d["seq"] as? NSNumber)?.uint64Value,
              let paneId = d["pane_id"] as? String,
              let kind = (d["kind"] as? String).flatMap(MessageKind.init(rawValue:)),
              let ts = d["ts"] as? Double else { return nil }
        self.init(seq: seq, paneId: paneId,
                  paneSessionKey: d["pane_session_key"] as? String ?? "",
                  kind: kind, ts: Date(timeIntervalSince1970: ts))
        text = d["text"] as? String
        tool = d["tool"] as? String
        detail = d["detail"] as? String
        isError = d["is_error"] as? Bool
        status = d["status"] as? String
        oldStatus = d["old_status"] as? String
        count = d["count"] as? Int ?? 1
    }
}

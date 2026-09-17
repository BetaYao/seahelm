import Foundation

enum MessageKind: String, Equatable {
    case user, assistant, tool, status, decision, notice
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
}

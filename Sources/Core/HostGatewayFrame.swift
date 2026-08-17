import Foundation

enum HostGatewayInbound {
    case request(id: String, method: String, params: [String: Any])
    case malformed
}

enum HostGatewayOutbound {
    case response(id: String, result: Any?, error: [String: Any]?)
    case notify(method: String, params: [String: Any])
}

enum HostGatewayFrame {
    static func parse(_ text: String) -> HostGatewayInbound {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String else {
            return .malformed
        }
        let id = (obj["id"] as? String) ?? (obj["id"].map { "\($0)" } ?? "")
        let params = obj["params"] as? [String: Any] ?? [:]
        return .request(id: id, method: method, params: params)
    }

    static func encode(_ outbound: HostGatewayOutbound) -> String {
        let obj: [String: Any]
        switch outbound {
        case .response(let id, let result, let error):
            var d: [String: Any] = ["id": id]
            if let error {
                d["error"] = error
            } else {
                d["result"] = result ?? NSNull()
            }
            obj = d
        case .notify(let method, let params):
            obj = ["type": "notify", "method": method, "params": params]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}

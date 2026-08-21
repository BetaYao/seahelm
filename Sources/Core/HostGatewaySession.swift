import Foundation

protocol HostGatewayVTAttaching: AnyObject {
    func open(paneSessionKey: String) -> [String: Any]
    func close(paneSessionKey: String)
    func keepalive(paneSessionKey: String)
    func sendKeys(paneSessionKey: String, utf8: Data) -> Bool
    var onNotify: ((String, [String: Any]) -> Void)? { get set }
}

final class HostGatewaySession {
    private let router: ControlRouter
    private let expectedMacId: String
    private let rootSecretBase64url: String
    private let vt: HostGatewayVTAttaching
    /// Shared with the server, which feeds it EventHub and fans out the results.
    private let decisions: HostGatewayDecisions
    private var authenticated = false
    private var openVTKeys: Set<String> = []
    private var pendingNotifications: [HostGatewayOutbound] = []
    /// Called after a notify is queued (e.g. server drains and sends on the connection).
    var onPendingOutbound: (() -> Void)?

    init(router: ControlRouter,
         expectedMacId: String,
         rootSecretBase64url: String,
         vt: HostGatewayVTAttaching,
         decisions: HostGatewayDecisions = HostGatewayDecisions()) {
        self.router = router
        self.expectedMacId = expectedMacId
        self.rootSecretBase64url = rootSecretBase64url
        self.vt = vt
        self.decisions = decisions
        vt.onNotify = { [weak self] method, params in
            self?.pendingNotifications.append(.notify(method: method, params: params))
            self?.onPendingOutbound?()
        }
    }

    /// Server → session: an event that opened or closed a decision.
    func pushDecision(_ change: HostGatewayDecisions.Change) {
        guard authenticated else { return }
        switch change {
        case .opened(let d):
            pendingNotifications.append(
                .notify(method: "pane.event", params: HostGatewayDecisions.notifyParams(for: d)))
        case .cleared(let key):
            pendingNotifications.append(
                .notify(method: "pane.event", params: HostGatewayDecisions.clearedParams(paneSessionKey: key)))
        case .none:
            return
        }
        onPendingOutbound?()
    }

    /// Answering locally clears it for everyone; other clients must be told.
    private func queueDecisionCleared(_ key: String) {
        pendingNotifications.append(
            .notify(method: "pane.event", params: HostGatewayDecisions.clearedParams(paneSessionKey: key)))
        onPendingOutbound?()
    }

    func drainNotifications() -> [String] {
        let out = pendingNotifications.map { HostGatewayFrame.encode($0) }
        pendingNotifications.removeAll()
        return out
    }

    func handle(text: String) -> [String] {
        switch HostGatewayFrame.parse(text) {
        case .malformed:
            return [encodeError(id: "", code: ControlError.parse, message: "parse error")]
        case .request(let id, let method, let params):
            if !authenticated {
                guard method == "auth" else {
                    return [encodeError(id: id, code: -32001, message: "unauthorized")]
                }
                return handleAuth(id: id, params: params)
            }
            return [handleAuthenticated(id: id, method: method, params: params)]
        }
    }

    private func handleAuth(id: String, params: [String: Any]) -> [String] {
        let macId = params["mac_id"] as? String ?? ""
        let token = params["token"] as? String ?? ""
        let ok = HostGatewayAuth.verify(
            macId: macId, token: token,
            expectedMacId: expectedMacId, rootSecretBase64url: rootSecretBase64url)
        if ok { authenticated = true }
        var out = [HostGatewayFrame.encode(.response(id: id, result: ["ok": ok], error: nil))]
        if ok {
            // Replay what is already open. Without this a client that connects a
            // second after a question is raised waits for an event it has missed.
            for d in decisions.pending() {
                out.append(HostGatewayFrame.encode(
                    .notify(method: "pane.event", params: HostGatewayDecisions.notifyParams(for: d))))
            }
        }
        return out
    }

    private func handleAuthenticated(id: String, method: String, params: [String: Any]) -> String {
        switch method {
        case "pane.vt_open":
            let key = paneSessionKey(from: params)
            let result = vt.open(paneSessionKey: key)
            // Only route send_keys to VT when open actually succeeded.
            if (result["ok"] as? Bool) != false {
                openVTKeys.insert(key)
            }
            return HostGatewayFrame.encode(.response(id: id, result: result, error: nil))
        case "pane.vt_close":
            let key = paneSessionKey(from: params)
            vt.close(paneSessionKey: key)
            openVTKeys.remove(key)
            return HostGatewayFrame.encode(.response(id: id, result: ["ok": true], error: nil))
        case "pane.vt_keepalive":
            let key = paneSessionKey(from: params)
            vt.keepalive(paneSessionKey: key)
            return HostGatewayFrame.encode(.response(id: id, result: ["ok": true], error: nil))
        case "question.answer":
            // The on-screen prompt is navigated, not addressed: move down `index`
            // times, then Return.
            let qKey = paneSessionKey(from: params)
            let qIndex = max(0, params["index"] as? Int ?? 0)
            var keys = Array(repeating: "down", count: qIndex)
            keys.append("enter")
            let answered = router.handle(method: "pane.send_keys",
                                         params: ["pane_id": qKey, "keys": keys])
            decisions.clear(paneSessionKey: qKey)
            queueDecisionCleared(qKey)
            return encodeControlResult(id: id, result: answered)
        case "suggest.pick":
            // A suggestion is text, so the chosen option is typed verbatim — the
            // index only means something next to the options we pushed.
            let sKey = paneSessionKey(from: params)
            let sIndex = max(0, params["index"] as? Int ?? 0)
            let opts = decisions.options(forPaneSessionKey: sKey)
            guard sIndex < opts.count else {
                return encodeError(id: id, code: ControlError.invalidParams,
                                   message: "no such suggestion")
            }
            let picked = router.handle(method: "pane.send_text",
                                       params: ["pane_id": sKey, "text": opts[sIndex], "enter": true])
            decisions.clear(paneSessionKey: sKey)
            queueDecisionCleared(sKey)
            return encodeControlResult(id: id, result: picked)
        case "decision.dismiss":
            // Two stores hold the same suggestion: this one, which feeds remote
            // clients, and FirstMate's pending orders, which the desktop island
            // draws. Declining has to reach both, or the card the user just
            // dismissed is still standing on the Mac.
            let dKey = paneSessionKey(from: params)
            decisions.clear(paneSessionKey: dKey)
            // Replayed on the next authentication if left open, so clearing the
            // local store is what stops a dismissal from coming back on reload.
            queueDecisionCleared(dKey)
            _ = router.handle(method: "decision.dismiss", params: ["pane_id": dKey])
            return HostGatewayFrame.encode(.response(id: id, result: ["dismissed": true], error: nil))
        case "pane.send_keys":
            if let key = vtKey(from: params), openVTKeys.contains(key),
               let utf8 = utf8Payload(from: params) {
                let sent = vt.sendKeys(paneSessionKey: key, utf8: utf8)
                return HostGatewayFrame.encode(.response(id: id, result: ["sent": sent], error: nil))
            }
            return encodeControlResult(id: id, result: router.handle(method: method, params: params))
        default:
            return encodeControlResult(id: id, result: router.handle(method: method, params: params))
        }
    }

    private func paneSessionKey(from params: [String: Any]) -> String {
        (params["pane_session_key"] as? String)
            ?? (params["pane_id"] as? String)
            ?? ""
    }

    private func vtKey(from params: [String: Any]) -> String? {
        let key = paneSessionKey(from: params)
        return key.isEmpty ? nil : key
    }

    private func utf8Payload(from params: [String: Any]) -> Data? {
        if let b64 = params["b64"] as? String, let data = Data(base64Encoded: b64) {
            return data
        }
        if let text = params["text"] as? String {
            return Data(text.utf8)
        }
        return nil
    }

    private func encodeControlResult(id: String, result: ControlResult) -> String {
        switch result {
        case .ok(let dict):
            return HostGatewayFrame.encode(.response(id: id, result: dict, error: nil))
        case .error(let code, let message):
            return encodeError(id: id, code: code, message: message)
        }
    }

    private func encodeError(id: String, code: Int, message: String) -> String {
        HostGatewayFrame.encode(.response(
            id: id, result: nil, error: ["code": code, "message": message]))
    }
}

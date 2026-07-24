import Foundation

enum ConnState: Equatable { case disconnected, connecting, connected }

/// HTTPS client for the Seahelm edge gateway (`gw.seahelm.dev`).
/// watchOS blocks `URLSessionWebSocketTask`; this polls `/api/v1/sync` and
/// publishes via `/api/v1/publish`, keeping the same Store-facing callbacks
/// as the old MQTT WebSocket client.
final class MQTTClient: NSObject {
    private let config: WatchConfig
    private let session: URLSession
    private var closed = false
    private var pollTimer: Timer?
    private var corrN = 0
    private var pending: [String: ([String: Any]) -> Void] = [:]
    private let crypto: WatchCrypto?
    private var cursor: Int = 0
    private var seenTopics = Set<String>()   // for retained tombstone detection across syncs
    // Short-code pairing (§7.5.4).
    private var pairNonce: Data?
    private var pairCode: String?
    private var onGrant: ((String?) -> Void)?

    var onState:    ((ConnState) -> Void)?
    var onError:    ((String?) -> Void)?
    var onPresence: ((Bool) -> Void)?
    var onDnd:      (([String: Any]) -> Void)?
    var onFocus:    (([String: Any]) -> Void)?
    var onPaneStatus: ((String, [String: Any]?) -> Void)?
    var onPaneEvent:  ((String, [String: Any]?) -> Void)?
    var onWorktree:   ((String, [String: Any]?) -> Void)?

    private var base: String { config.base }
    private var replyBase: String { "\(base)/reply/\(WatchConfig.clientId)" }
    private var apiRoot: String {
        config.gatewayBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    init(config: WatchConfig) {
        self.config = WatchConfig.resolved(config)
        self.crypto = WatchCrypto(rootSecretBase64url: config.rootSecret)
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    // MARK: - Lifecycle

    func connect() {
        closed = false
        guard !config.gatewayAPIKey.isEmpty else {
            deliver {
                self.onError?("未配置 Gateway API Key")
                self.onState?(.disconnected)
            }
            return
        }
        deliver {
            self.onError?(nil)
            self.onState?(.connecting)
        }
        cursor = 0
        seenTopics.removeAll()
        pollOnce(isFirst: true)
        DispatchQueue.main.async {
            self.pollTimer?.invalidate()
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.pollOnce(isFirst: false)
            }
        }
    }

    func disconnect() {
        closed = true
        pollTimer?.invalidate(); pollTimer = nil
        cancelPairing()
        deliver { self.onState?(.disconnected) }
    }

    func cancelPairing() {
        guard onGrant != nil else { return }
        pairNonce = nil; pairCode = nil
        let cb = onGrant; onGrant = nil
        deliver { cb?(nil) }
    }

    // MARK: - Poll

    private func pollOnce(isFirst: Bool) {
        guard !closed else { return }
        var comps = URLComponents(string: "\(apiRoot)/api/v1/sync")!
        comps.queryItems = [
            URLQueryItem(name: "mac_id", value: config.macId),
            URLQueryItem(name: "after", value: String(cursor)),
        ]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(config.gatewayAPIKey)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self, !self.closed else { return }
            if let err {
                self.deliver {
                    self.onError?(err.localizedDescription)
                    self.onState?(.disconnected)
                }
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["ok"] as? Bool == true else {
                let msg = String(data: data ?? Data(), encoding: .utf8) ?? "HTTP \(code)"
                self.deliver {
                    self.onError?(code == 401 ? "API Key 无效" : msg)
                    self.onState?(.disconnected)
                }
                return
            }

            if let cur = obj["cursor"] as? Int { self.cursor = cur }
            else if let cur = obj["cursor"] as? Double { self.cursor = Int(cur) }

            self.deliver {
                self.onError?(nil)
                self.onState?(.connected)
            }

            // Retained snapshot (full map each sync).
            if let messages = obj["messages"] as? [String: String] {
                let current = Set(messages.keys)
                if isFirst || self.cursor > 0 {
                    for topic in self.seenTopics.subtracting(current) {
                        self.route(topic: topic, payload: Data())
                    }
                }
                self.seenTopics = current
                for (topic, payload) in messages {
                    self.route(topic: topic, payload: Data(payload.utf8))
                }
            }

            // Incremental events (pair grant, replies, live pane/event, …).
            // Retained updates already applied from `messages`.
            if let evs = obj["events"] as? [[String: Any]] {
                for ev in evs {
                    if (ev["retain"] as? Bool) == true { continue }
                    guard let topic = ev["topic"] as? String else { continue }
                    let payload = ev["payload"] as? String ?? ""
                    self.route(topic: topic, payload: Data(payload.utf8))
                }
            }
        }.resume()
    }

    // MARK: - Route (same contract as the old MQTT client)

    private func route(topic: String, payload: Data) {
        if let nonce = pairNonce, let code = pairCode,
           topic == "\(base)/pair/grant/\(WatchCrypto.base64url(nonce))" {
            let env = String(data: payload, encoding: .utf8) ?? ""
            let secret = WatchCrypto.open(env, topic: topic, key: WatchCrypto.codeKey(code, nonce: nonce))
            let cb = onGrant; pairNonce = nil; pairCode = nil; onGrant = nil
            deliver { cb?(secret) }
            return
        }
        var raw = String(data: payload, encoding: .utf8) ?? ""
        if let crypto, !raw.isEmpty {
            guard let opened = crypto.open(raw, topic: topic) else { return }
            raw = opened
        }
        let obj = raw.data(using: .utf8).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let parts = topic.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return }
        let seg = Array(parts[2...])
        deliver { [self] in
            switch seg.first {
            case "pane" where seg.count >= 3:
                let slot = seg[1]
                switch seg[2] {
                case "status": onPaneStatus?(slot, raw.isEmpty ? nil : obj)
                case "event":  onPaneEvent?(slot, raw.isEmpty ? nil : obj)
                default: break
                }
            case "worktree" where seg.count >= 3 && seg[2] == "status":
                onWorktree?(seg[1], raw.isEmpty ? nil : obj)
            case "focus":    if let obj { onFocus?(obj) }
            case "presence": onPresence?((obj?["online"] as? Bool) ?? false)
            case "dnd":      if let obj { onDnd?(obj) }
            case "reply" where seg.count >= 3:
                let corr = seg[seg.count - 1]
                if let cb = pending.removeValue(forKey: corr), let obj { cb(obj) }
            default: break
            }
        }
    }

    // MARK: - Outbound

    func resolve(paneSessionKey: String, questionId: String?, suggestId: String?, index: Int) {
        if let qid = questionId {
            command("question.answer", ["pane_session_key": paneSessionKey, "question_id": qid, "index": index])
        } else if let sid = suggestId {
            command("suggest.pick", ["pane_session_key": paneSessionKey, "suggest_id": sid, "index": index])
        }
    }
    func sendText(paneSessionKey: String, text: String) {
        command("pane.send_text", ["pane_session_key": paneSessionKey, "text": text, "enter": true])
    }
    func setDnd(on: Bool, minutes: Int) { command("dnd.set", ["on": on, "minutes": minutes]) }

    func pairWithCode(_ code: String, then: @escaping (String?) -> Void) {
        guard !closed else { then(nil); return }
        let nonce = WatchCrypto.randomNonce()
        pairNonce = nonce; pairCode = code; onGrant = then
        publishJSON("\(base)/pair/claim", ["code": code, "nonce": nonce.base64EncodedString()])
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.pairNonce == nonce else { return }
            self.pairNonce = nil; self.pairCode = nil
            let cb = self.onGrant; self.onGrant = nil; cb?(nil)
        }
    }

    private func command(_ method: String, _ params: [String: Any]) {
        corrN += 1
        let corr = "c\(corrN)"
        publishJSON("\(base)/command",
                    ["method": method, "params": params, "reply_to": "\(replyBase)/\(corr)", "corr": corr])
    }

    func history(paneSessionKey: String, limit: Int = 10, reply: @escaping ([[String: Any]]) -> Void) {
        corrN += 1
        let corr = "h\(corrN)"
        pending[corr] = { obj in
            reply((obj["result"] as? [String: Any])?["messages"] as? [[String: Any]] ?? [])
        }
        publishJSON("\(base)/history/request",
                    ["pane_session_key": paneSessionKey, "limit": limit, "reply_to": "\(replyBase)/\(corr)", "corr": corr])
    }

    private func publishJSON(_ topic: String, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return }
        let wire = crypto?.seal(json, topic: topic) ?? json
        publish(topic: topic, payload: wire, retain: false)
    }

    private func publish(topic: String, payload: String, retain: Bool) {
        guard let url = URL(string: "\(apiRoot)/api/v1/publish") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.gatewayAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["topic": topic, "payload": payload, "qos": 1, "retain": retain]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: req) { [weak self] _, resp, err in
            guard let self else { return }
            if let err {
                self.deliver { self.onError?(err.localizedDescription) }
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                self.deliver { self.onError?("publish HTTP \(code)") }
            }
        }.resume()
    }

    private func deliver(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }
}

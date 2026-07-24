import Foundation
import CocoaMQTT
import CocoaMQTTWebSocket

/// MQTT remote-client backend (CocoaMQTT). The Mac is the single publisher on the
/// broker: it publishes retained pane/worktree/focus/presence state, and answers
/// `command` / `history/request` from clients (Watch / web / ESP32).
///
/// Protocol: MQTT 3.1.1 minimal set (retained / LWT / QoS1); request-reply carries
/// `reply_to` + `corr` in the JSON payload, not MQTT5 properties. See
/// `docs/remote-clients-design.md` §15. The executable reference for the wire
/// behavior is `clients/seahelm-web/devbroker/mock-seahelm.js`.
///
/// Conforms to `ExternalChannel` so registering it with `ShipLog` also mirrors
/// desktop notifications for free (`send(_:)`), and reconnect/backoff mirrors
/// `WeComBotChannel`.
///
/// This file is the **skeleton** (Phase 0 step 3): connect / TLS / auth / LWT /
/// presence / reconnect. Status publishing (step 5) and command routing (step 7)
/// are marked `// TODO(phase0)` below.
final class MqttChannel: NSObject, ExternalChannel {
    let channelId: String
    let channelType: ExternalChannelType = .mqtt
    var onMessage: ((InboundMessage) -> Void)?

    /// Notified on gateway state changes (mirror of `WeComBotChannel`).
    var onStateChange: ((GatewayState) -> Void)?

    /// Snapshot/command bridge (same instance the Unix `ControlRouter` uses).
    /// Set after init; used to publish full pane state and run commands. Held
    /// strongly (the bridge captures its owner weakly, so no retain cycle).
    var dataSource: ControlDataSource?

    private let config: MqttConfig
    private var eventToken: Int?
    private let history = PaneHistoryBuffer()

    /// Each inbound command runs on its own worker so a blocking `wait.*` (which
    /// polls with `Thread.sleep`, see `ControlProtocol.swift:320`) stalls only
    /// that request, never the MQTT callback thread.
    private let cmdQueue = DispatchQueue(label: "seahelm.mqtt.command", attributes: .concurrent)

    /// Mutating / blocking methods gated behind `allowRemoteWrite`. Read methods
    /// (ping/snapshot/read/options/explain/export) are always allowed.
    private static let gatedMethods: Set<String> = [
        "pane.send_text", "pane.run", "pane.send_keys", "pane.split", "pane.zoom",
        "pane.close", "pane.focus", "layout.apply", "suggest",
        "pane.wait_for_output", "wait.output", "pane.wait_agent_status", "wait.agent_status",
        "question.answer", "suggest.pick", "dnd.set",
    ]

    /// Last published question/suggest per slot (options text), so `suggest.pick`
    /// can map an index back to the chosen order. Touched from both the EventHub
    /// (main) and MQTT command threads → guarded by `pendLock`.
    private var pendingEvents: [String: [String]] = [:]
    private var dndState: [String: Any] = ["on": false, "minutes": 25, "blocked": 0]
    private let pendLock = NSLock()

    /// Active short pairing code (§7.5.4): single-use, TTL-bounded. A `pair/claim`
    /// matching this trades the code for the (code-key-encrypted) root secret.
    private var pairCode: (code: String, expires: Date)?
    private let pairLock = NSLock()

    /// Register/clear the active pairing short code (called from the pairing UI).
    func setPairingCode(_ code: String?, ttl: TimeInterval) {
        pairLock.lock(); defer { pairLock.unlock() }
        pairCode = code.map { ($0, Date().addingTimeInterval(ttl)) }
    }
    private let macId: String
    /// E2EE + derived broker auth, present only when the Mac is paired
    /// (`config.rootSecret` set). Nil = plaintext/manual-credential mode.
    private let crypto: MqttCrypto?
    private var stateMachine = GatewayStateMachine()
    private(set) var gatewayState: GatewayState = .disconnected

    private var mqtt: CocoaMQTT?
    private var reconnectAttempt = 0
    private var reconnectTimer: Timer?
    private var seq: Int = 0
    private let lock = NSLock()

    // MARK: Topics
    private var base: String { "seahelm/\(macId)" }
    private var tPresence: String { "\(base)/presence" }
    private var tCommand: String { "\(base)/command" }
    private var tHistoryRequest: String { "\(base)/history/request" }

    init(config: MqttConfig, channelId: String? = nil) {
        self.config = config
        self.macId = config.macId ?? MqttChannel.deriveMacId()
        self.channelId = channelId ?? "mqtt-\(self.macId)"
        if let rs = config.rootSecret, let bytes = MqttCrypto.rootSecret(fromBase64url: rs) {
            self.crypto = MqttCrypto(rootSecret: bytes)
        } else {
            self.crypto = nil
        }
        super.init()
    }

    deinit { disconnect() }

    // MARK: - ExternalChannel

    func connect() {
        guard stateMachine.transition(to: .connecting) else { return }
        gatewayState = stateMachine.state
        onStateChange?(gatewayState)
        reconnectAttempt = 0

        // Mirror every committed status change onto the broker (retained).
        if eventToken == nil {
            eventToken = EventHub.shared.subscribe { [weak self] seq, ev in
                self?.handleEvent(seq: seq, event: ev)
            }
        }

        let clientId = config.clientId ?? "seahelm-\(macId)"
        // Transport by config: native MQTT(-TLS) on TCP (the Mac/ESP/mobile path),
        // or MQTT-over-WebSocket(-TLS) for parity with the web/Watch clients. The
        // native-TLS path needs an explicit SNI peer name for EMQX Serverless (below).
        let m: CocoaMQTT
        if config.resolvedWebsocket {
            let ws = CocoaMQTTWebSocket(uri: config.resolvedWsPath)
            ws.enableSSL = config.resolvedTLS      // wss:// — the WS socket has its own SSL flag
            m = CocoaMQTT(clientID: clientId, host: config.host, port: config.resolvedPort, socket: ws)
        } else {
            m = CocoaMQTT(clientID: clientId, host: config.host, port: config.resolvedPort)
            // Native MQTT-TLS (8883). EMQX Cloud Serverless is multi-tenant behind a
            // shared LB that routes by TLS SNI. GCDAsyncSocket (CocoaMQTT's TCP socket)
            // only emits SNI when kCFStreamSSLPeerName is set in sslSettings — without
            // it the handshake lands on the wrong tenant and CONNECT is rejected with
            // notAuthorized (even with correct creds). Set the peer name explicitly.
            if config.resolvedTLS {
                m.sslSettings = [kCFStreamSSLPeerName as String: config.host as NSObject]
            }
        }
        // Broker auth is fixed dev creds from config (e.g. seahelm/seahelm),
        // decoupled from mac_id and the E2EE root secret — so mac_id can be a
        // per-machine namespace without needing a per-id broker user. Crypto (if
        // paired) still seals/opens payloads; it no longer supplies broker creds.
        m.username = config.username
        m.password = config.password
        m.keepAlive = 60
        m.enableSSL = config.resolvedTLS
        m.autoReconnect = false          // we manage exponential backoff ourselves
        m.cleanSession = true

        // LWT: broker publishes offline (retained) if we drop unexpectedly.
        let willBody = encode(["online": false, "seq": 0])
        let will = CocoaMQTTMessage(topic: tPresence,
                                    string: crypto?.seal(willBody, topic: tPresence) ?? willBody,
                                    qos: .qos1, retained: true)
        m.willMessage = will
        m.delegate = self
        mqtt = m

        NSLog("[MqttChannel] connecting \(config.resolvedTLS ? "mqtts" : "mqtt")://\(config.host):\(config.resolvedPort) as \(clientId)")
        _ = m.connect()
    }

    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        if let eventToken { EventHub.shared.unsubscribe(eventToken) }
        eventToken = nil
        mqtt?.disconnect()
        mqtt = nil
        updateState(.disconnected)
    }

    /// Notification mirroring: any desktop notification broadcast to registered
    /// channels lands here → published as a (non-retained) notification event.
    func send(_ message: OutboundMessage) {
        // TODO(phase0): shape into a proper pane/{id}/event notification once the
        // event schema is wired (step 5). For now mirror to a channel-level topic.
        publish("\(base)/notification",
                ["text": message.content, "seq": nextSeq()], retained: false)
    }

    // MARK: - Publish helper

    @discardableResult
    private func publish(_ topic: String, _ obj: [String: Any], retained: Bool) -> Bool {
        guard let mqtt, stateMachine.isConnected else { return false }
        let body = encode(obj)
        // Seal per-topic (topic = AES-GCM AAD) when paired; else publish plaintext.
        let wire = crypto?.seal(body, topic: topic) ?? body
        _ = mqtt.publish(topic, withString: wire, qos: .qos1, retained: retained)
        return true
    }

    /// Delete a retained topic by publishing a zero-length retained payload — the
    /// MQTT idiom for "this topic no longer has a value" (used on pane close).
    private func clearRetained(_ topic: String) {
        guard let mqtt, stateMachine.isConnected else { return }
        _ = mqtt.publish(topic, withString: "", qos: .qos1, retained: true)
    }

    private func nextSeq() -> Int { lock.lock(); defer { lock.unlock() }; seq += 1; return seq }

    private func encode(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: Topics (dynamic)
    private func tPaneStatus(_ id: String) -> String { "\(base)/pane/\(id)/status" }
    private func tPaneMessage(_ id: String) -> String { "\(base)/pane/\(id)/message" }
    private func tPaneEvent(_ id: String) -> String { "\(base)/pane/\(id)/event" }
    private func tWorktreeStatus(_ id: String) -> String { "\(base)/worktree/\(id)/status" }
    private var tFocus: String { "\(base)/focus" }
    private var tDnd: String { "\(base)/dnd/state" }
    private var tPairClaim: String { "\(base)/pair/claim" }

    private static let dangerRE = try? NSRegularExpression(
        pattern: "覆盖|删除|prod|生产|部署|deploy|drop|force", options: [.caseInsensitive])
    private static func isDanger(_ s: String) -> Bool {
        guard let re = dangerRE else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// The stable per-pane slot key used as the pane topic segment and the remote
    /// addressing key (§15). `pane_session_key` survives app restarts, so the same
    /// pane republishes to the same topic (no orphaned retained ghosts); the
    /// per-instance `pane_id` UUID rides in the payload for debugging only. Falls
    /// back to `pane_id` for a session-less (local backend) pane.
    private func slot(_ pane: PaneSnapshot) -> String {
        pane.paneSessionKey.isEmpty ? pane.paneId : pane.paneSessionKey
    }
    private func slot(paneId: String, paneSessionKey: String) -> String {
        paneSessionKey.isEmpty ? paneId : paneSessionKey
    }

    // MARK: - Publishing

    /// EventHub → publish the changed pane's full retained status + the raw event
    /// as a (non-retained) message, then recompute worktree rollups + focus.
    private func handleEvent(seq: UInt64, event: [String: Any]) {
        guard stateMachine.isConnected else { return }
        let pid = (event["pane_id"] as? String) ?? ""
        let sname = (event["pane_session_key"] as? String) ?? ""
        let key = slot(paneId: pid, paneSessionKey: sname)
        let panes = dataSource?.snapshotPanes() ?? []

        // A pane closed: clear its retained slot topics so remote clients drop the
        // ghost immediately, then republish rollups (pane count changed).
        if (event["type"] as? String) == "pane.closed" {
            clearRetained(tPaneStatus(key))   // empty retained = delete the ghost
            publishWorktreesAndFocus(from: panes)
            return
        }

        if let pane = panes.first(where: { $0.paneId == pid || $0.paneSessionKey == sname }) {
            publishPaneStatus(pane, seq: Int(seq))
        }
        publish(tPaneMessage(key), event, retained: false)   // feed (event verbatim)
        // History = the agent's real final message per turn. Only a completion event
        // carries `final_message` (the Stop hook's last_assistant_message); status-
        // settle `last_message` is often a scanned tool/file line, so we no longer
        // key on it. See ShipLog.event(from:). Keyed by the stable slot.
        if (event["is_completion"] as? Bool) == true,
           let text = event["final_message"] as? String, !text.isEmpty {
            history.append(paneId: key, entry: ["seq": Int(seq), "kind": "agent", "text": text])
        }
        // User side of the conversation: record what the user typed so history
        // shows both turns (user prompt → assistant final), not just the answer.
        if let prompt = event["user_prompt"] as? String, !prompt.isEmpty {
            history.append(paneId: key, entry: ["seq": Int(seq), "kind": "you", "text": prompt])
        }
        publishDecision(slot: key, pid: pid, sname: sname, event: event, seq: Int(seq))
        publishWorktreesAndFocus(from: panes)
    }

    /// Surface an open decision (question / suggest) as a **retained** `pane/event`
    /// so a client connecting any time sees the pending order; clear it (empty
    /// retained) once the pane leaves `.waiting`. Backs the Watch Orders/Confirm.
    private func publishDecision(slot key: String, pid: String, sname: String,
                                 event: [String: Any], seq: Int) {
        if let q = event["question"] as? [String: Any] {
            let prompt = q["prompt"] as? String ?? ""
            let options = q["options"] as? [String] ?? []
            pendLock.lock(); pendingEvents[key] = options; pendLock.unlock()
            publish(tPaneEvent(key), ["type": "question", "pane_id": pid, "pane_session_key": sname,
                                      "prompt": prompt, "options": options,
                                      "danger": Self.isDanger(prompt), "seq": seq], retained: true)
        } else if let s = event["suggest"] as? [String: Any] {
            let options = s["options"] as? [String] ?? []
            pendLock.lock(); pendingEvents[key] = options; pendLock.unlock()
            publish(tPaneEvent(key), ["type": "suggest", "pane_id": pid, "pane_session_key": sname,
                                      "options": options, "seq": seq], retained: true)
        } else if let st = event["status"] as? String, st != SailorStatus.waiting.rawValue {
            clearDecision(key)
        }
    }

    /// Drop a pane's retained decision (answered/resolved/moved on).
    private func clearDecision(_ key: String?) {
        guard let key, !key.isEmpty else { return }
        pendLock.lock(); let had = pendingEvents.removeValue(forKey: key) != nil; pendLock.unlock()
        if had { clearRetained(tPaneEvent(key)) }
    }

    /// Publish every pane (retained) + worktree rollups + focus — so a client that
    /// connects any time gets the full last-known state immediately.
    private func publishFullSnapshot() {
        let panes = dataSource?.snapshotPanes() ?? []
        for p in panes { publishPaneStatus(p, seq: nextSeq()) }
        publishWorktreesAndFocus(from: panes)
        pendLock.lock(); var dnd = dndState; pendLock.unlock()
        dnd["seq"] = nextSeq()
        publish(tDnd, dnd, retained: true)      // so a fresh client gets DND state
    }

    private func publishPaneStatus(_ pane: PaneSnapshot, seq: Int) {
        var dict = pane.dict            // verbatim PaneSnapshot.dict (§3)
        dict["seq"] = seq
        publish(tPaneStatus(slot(pane)), dict, retained: true)   // topic keyed by stable slot
    }

    private func publishWorktreesAndFocus(from panes: [PaneSnapshot]) {
        var groups: [String: [PaneSnapshot]] = [:]
        for p in panes { groups[p.worktreePath, default: []].append(p) }
        for (path, list) in groups {
            let id = path.split(separator: "/").last.map(String.init) ?? path
            let first = list[0]
            publish(tWorktreeStatus(id), [
                "worktree_id": id, "worktree_path": path,
                "branch": first.branch, "project": first.project,
                "status": rolledStatus(list).rawValue,
                "pane_count": list.count, "seq": nextSeq(),
            ], retained: true)
        }
        publishFocus(from: panes)
    }

    /// Single-focus selection: the one thing most worth showing now (§5).
    private func publishFocus(from panes: [PaneSnapshot]) {
        func count(_ s: SailorStatus) -> Int { panes.filter { $0.status == s.rawValue }.count }
        let focus = panes.min { focusRank($0.status) < focusRank($1.status) }
        var dict: [String: Any] = [
            "counts": ["running": count(.running), "waiting": count(.waiting),
                       "failed": count(.error), "total": panes.count],
            "seq": nextSeq(),
        ]
        if let f = focus {
            dict["pane_id"] = f.paneId
            dict["kind"] = focusKind(f.status)
            dict["headline"] = f.agentType
            dict["line"] = f.lastMessage
            dict["worktree"] = f.branch
        }
        publish(tFocus, dict, retained: true)
    }

    /// Attention priority: lower = more worth showing (waiting > error > running …).
    private func focusRank(_ raw: String) -> Int {
        switch SailorStatus(rawValue: raw) ?? .unknown {
        case .waiting: return 0
        case .error:   return 1
        case .running: return 2
        case .exited:  return 3
        case .idle:    return 4
        case .unknown: return 5
        }
    }
    private func focusKind(_ raw: String) -> String {
        switch SailorStatus(rawValue: raw) ?? .unknown {
        case .waiting, .error: return "blocked"
        case .running:         return "working"
        case .exited:          return "say"
        default:               return "idle"
        }
    }
    private func rolledStatus(_ list: [PaneSnapshot]) -> SailorStatus {
        let top = list.min { focusRank($0.status) < focusRank($1.status) }
        return SailorStatus(rawValue: top?.status ?? "") ?? .unknown
    }

    // MARK: - Inbound commands / history

    /// `{method, params, reply_to, corr}` → run on a worker via `ControlRouter`,
    /// reply `{ok, result|error, corr}` to `reply_to`. Write methods gated by
    /// `allowRemoteWrite`.
    private func handleCommand(_ env: [String: Any]) {
        let method = env["method"] as? String ?? ""
        var params = env["params"] as? [String: Any] ?? [:]
        let replyTo = env["reply_to"] as? String
        let corr = env["corr"] as? String

        // Remote clients address a pane by its stable `pane_session_key` (§15);
        // resolve it to the internal per-instance `pane_id` (UUID) that
        // `ControlRouter` works in. A caller that still sends `pane_id` is left
        // untouched (backward compatible).
        if params["pane_id"] == nil, let key = params["pane_session_key"] as? String,
           let pane = dataSource?.snapshotPanes().first(where: { $0.paneSessionKey == key }) {
            params["pane_id"] = pane.paneId
        }

        if Self.gatedMethods.contains(method), !config.resolvedAllowRemoteWrite {
            reply(to: replyTo, corr: corr,
                  result: .error(code: -32003, message: "capability_denied: remote write disabled"))
            return
        }

        // Watch decision / DND methods are handled here (kept out of ControlRouter /
        // the desktop UI). `question.answer` navigates the on-screen prompt by
        // index; `suggest.pick` sends the chosen order text; `dnd.set` reflects
        // state to a retained `dnd/state` topic.
        switch method {
        case "question.answer":
            let idx = max(0, params["index"] as? Int ?? 0)
            if let pid = params["pane_id"] as? String {
                var keys = Array(repeating: "down", count: idx); keys.append("enter")
                _ = dataSource?.sendKeys(paneId: pid, keys: keys)
            }
            clearDecision(params["pane_session_key"] as? String)
            reply(to: replyTo, corr: corr, result: .ok(["answered": true])); return
        case "suggest.pick":
            let idx = max(0, params["index"] as? Int ?? 0)
            let key = params["pane_session_key"] as? String ?? ""
            pendLock.lock(); let opts = pendingEvents[key] ?? []; pendLock.unlock()
            if let pid = params["pane_id"] as? String, idx < opts.count {
                _ = dataSource?.sendText(paneId: pid, text: opts[idx], enter: true)
            }
            clearDecision(key)
            reply(to: replyTo, corr: corr, result: .ok(["picked": true])); return
        case "dnd.set":
            let on = params["on"] as? Bool ?? false
            let minutes = params["minutes"] as? Int ?? 25
            pendLock.lock(); dndState = ["on": on, "minutes": minutes, "blocked": dndState["blocked"] ?? 0]
            let snap = dndState; pendLock.unlock()
            var out = snap; out["seq"] = nextSeq()
            publish(tDnd, out, retained: true)
            reply(to: replyTo, corr: corr, result: .ok(["on": on])); return
        default: break
        }

        let ds = dataSource
        cmdQueue.async { [weak self] in
            let router = ControlRouter(dataSource: ds)
            let result = router.handle(method: method, params: params)
            self?.reply(to: replyTo, corr: corr, result: result)
        }
    }

    /// `{pane_session_key|pane_id, limit, before_seq, reply_to, corr}` → reply from
    /// the per-pane JSONL buffer (`PaneHistoryBuffer`). History is keyed by the
    /// stable slot (`pane_session_key`), so it survives restarts; `pane_id` is
    /// accepted as a fallback for older clients.
    private func handleHistory(_ env: [String: Any]) {
        let replyTo = env["reply_to"] as? String
        let corr = env["corr"] as? String
        let key = (env["pane_session_key"] as? String) ?? (env["pane_id"] as? String) ?? ""
        let limit = env["limit"] as? Int ?? 50
        let beforeSeq = env["before_seq"] as? Int
        let (messages, hasMore) = history.messages(paneId: key, limit: limit, beforeSeq: beforeSeq)
        reply(to: replyTo, corr: corr, result: .ok(["messages": messages, "has_more": hasMore]))
    }

    /// Short-code pairing (§7.5.4): validate `{code, nonce}` against the active
    /// single-use code, then deliver the root secret to `pair/grant/{nonce}`
    /// encrypted with a key derived from the code (broker never sees it plaintext).
    private func handlePairClaim(_ env: [String: Any]) {
        guard let code = env["code"] as? String,
              let nonceB64 = env["nonce"] as? String,
              let nonce = Data(base64Encoded: nonceB64) else { return }
        pairLock.lock()
        let active = pairCode
        let ok = active != nil && active!.code == code && active!.expires > Date()
        if ok { pairCode = nil }                       // single-use: burn on first valid claim
        pairLock.unlock()
        guard ok, let secret = config.rootSecret, !secret.isEmpty else { return }
        let grantTopic = "\(base)/pair/grant/\(MqttCrypto.base64url(nonce))"
        let key = MqttCrypto.codeKey(code, nonce: nonce)
        publishRaw(grantTopic, MqttCrypto.seal(secret, topic: grantTopic, key: key))
        NSLog("[MqttChannel] pairing: root secret granted via short code")
    }

    /// Publish a pre-encoded string verbatim (no E2EE re-seal) — used for the
    /// pairing grant, which is already sealed with the code-derived key.
    private func publishRaw(_ topic: String, _ string: String) {
        guard let mqtt, stateMachine.isConnected, !string.isEmpty else { return }
        _ = mqtt.publish(topic, withString: string, qos: .qos1, retained: false)
    }

    private func reply(to topic: String?, corr: String?, result: ControlResult) {
        guard let topic else { return }
        var obj: [String: Any]
        switch result {
        case .ok(let r):
            obj = ["ok": true, "result": r]
        case .error(let code, let message):
            obj = ["ok": false, "error": ["code": code, "message": message]]
        }
        if let corr { obj["corr"] = corr }
        publish(topic, obj, retained: false)
    }

    private func decode(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - State & reconnect (mirror WeComBotChannel)

    private func updateState(_ newState: GatewayState) {
        guard stateMachine.transition(to: newState) else { return }
        gatewayState = stateMachine.state
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStateChange?(self.gatewayState)
        }
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt)), config.resolvedMaxReconnectInterval)
        NSLog("[MqttChannel] reconnect in \(delay)s (attempt \(reconnectAttempt))")
        DispatchQueue.main.async { [weak self] in
            self?.reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard let self else { return }
                // reset to disconnected so the state machine allows connecting again
                self.stateMachine.transition(to: .disconnected)
                self.connect()
            }
        }
    }

    /// Stable, non-PII namespace id derived from the host name. Overridable via
    /// `MqttConfig.macId`. djb2 hash → short hex (no machine name leaks in topics).
    static func deriveMacId() -> String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        var h: UInt64 = 5381
        for b in name.utf8 { h = (h &* 33) ^ UInt64(b) }
        return "m" + String(h & 0xFFFFFFFF, radix: 16)
    }
}

// MARK: - CocoaMQTTDelegate

extension MqttChannel: CocoaMQTTDelegate {
    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        guard ack == .accept else {
            NSLog("[MqttChannel] connect refused: \(ack)")
            updateState(.error("connack \(ack)"))
            scheduleReconnect()
            return
        }
        reconnectAttempt = 0
        updateState(.connected)
        NSLog("[MqttChannel] connected")

        // presence online (retained)
        publish(tPresence, ["online": true, "seq": nextSeq()], retained: true)

        // inbound channels
        mqtt.subscribe(tCommand, qos: .qos1)
        mqtt.subscribe(tHistoryRequest, qos: .qos1)
        mqtt.subscribe(tPairClaim, qos: .qos1)   // short-code pairing (plaintext)

        // full retained snapshot so a client that connects while Mac is up (or
        // after) immediately has every pane/worktree + the single focus.
        publishFullSnapshot()
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        let topic = message.topic
        guard let payload = message.string else { return }
        // Short-code pairing claims are PLAINTEXT (the client isn't paired yet), so
        // handle them before the E2EE-open guard would drop them.
        if topic == tPairClaim {
            if let env = decode(payload) { handlePairClaim(env) }
            return
        }
        // Open the E2EE envelope when paired; drop anything that fails to decrypt.
        let plain: String
        if let crypto {
            guard let opened = crypto.open(payload, topic: topic) else { return }
            plain = opened
        } else {
            plain = payload
        }
        guard let env = decode(plain) else { return }
        if topic == tCommand {
            handleCommand(env)
        } else if topic == tHistoryRequest {
            handleHistory(env)
        }
    }

    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        NSLog("[MqttChannel] disconnected: \(err?.localizedDescription ?? "clean")")
        if err != nil {
            updateState(.error(err!.localizedDescription))
            scheduleReconnect()
        } else {
            updateState(.disconnected)
        }
    }

    // Remaining required delegate methods — no-ops for the skeleton.
    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}

    /// WebSocket(-TLS) server-trust challenge. CocoaMQTT only forwards this to this
    /// (optional) delegate method — if unimplemented, the completion handler is
    /// never called and the wss:// handshake hangs forever (the EMQX Cloud symptom).
    /// EMQX Cloud uses a public CA (DigiCert), so default system trust is correct.
    func mqttUrlSession(_ mqtt: CocoaMQTT, didReceiveTrust trust: SecTrust,
                        didReceiveChallenge challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}

import Foundation
import CocoaMQTT

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
    ]
    private let macId: String
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

        if config.resolvedWebsocket {
            // The Mac publisher connects over TCP; WS is for browser/Watch clients
            // (needs the CocoaMQTTWebSocket product, not linked here).
            NSLog("[MqttChannel] config requests websocket; Mac publisher uses TCP — connecting TCP.")
        }

        let clientId = config.clientId ?? "seahelm-\(macId)"
        let m = CocoaMQTT(clientID: clientId, host: config.host, port: config.resolvedPort)
        m.username = config.username
        m.password = config.password
        m.keepAlive = 60
        m.enableSSL = config.resolvedTLS
        m.autoReconnect = false          // we manage exponential backoff ourselves
        m.cleanSession = true

        // LWT: broker publishes offline (retained) if we drop unexpectedly.
        let will = CocoaMQTTMessage(topic: tPresence,
                                    string: encode(["online": false, "seq": 0]),
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
        _ = mqtt.publish(topic, withString: encode(obj), qos: .qos1, retained: retained)
        return true
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
    private func tWorktreeStatus(_ id: String) -> String { "\(base)/worktree/\(id)/status" }
    private var tFocus: String { "\(base)/focus" }

    // MARK: - Publishing

    /// EventHub → publish the changed pane's full retained status + the raw event
    /// as a (non-retained) message, then recompute worktree rollups + focus.
    private func handleEvent(seq: UInt64, event: [String: Any]) {
        guard stateMachine.isConnected else { return }
        let pid = (event["pane_id"] as? String) ?? ""
        let sname = (event["session_name"] as? String) ?? ""
        let panes = dataSource?.snapshotPanes() ?? []
        if let pane = panes.first(where: { $0.paneId == pid || $0.sessionName == sname }) {
            publishPaneStatus(pane, seq: Int(seq))
        }
        publish(tPaneMessage(pid), event, retained: false)   // feed (event verbatim)
        // History = final message per turn only. Append when a turn settles (a
        // status change to a non-Running state), skipping the noisy mid-turn
        // last_message churn (tool/file/command lines) that pane.updated events and
        // Running transitions carry.
        if (event["type"] as? String) == "pane.status_changed",
           let ns = event["status"] as? String, ns != SailorStatus.running.rawValue,
           let text = event["last_message"] as? String, !text.isEmpty {
            history.append(paneId: pid, entry: ["seq": Int(seq), "kind": "agent", "text": text])
        }
        publishWorktreesAndFocus(from: panes)
    }

    /// Publish every pane (retained) + worktree rollups + focus — so a client that
    /// connects any time gets the full last-known state immediately.
    private func publishFullSnapshot() {
        let panes = dataSource?.snapshotPanes() ?? []
        for p in panes { publishPaneStatus(p, seq: nextSeq()) }
        publishWorktreesAndFocus(from: panes)
    }

    private func publishPaneStatus(_ pane: PaneSnapshot, seq: Int) {
        var dict = pane.dict            // verbatim PaneSnapshot.dict (§3)
        dict["seq"] = seq
        publish(tPaneStatus(pane.paneId), dict, retained: true)
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
        let params = env["params"] as? [String: Any] ?? [:]
        let replyTo = env["reply_to"] as? String
        let corr = env["corr"] as? String

        if Self.gatedMethods.contains(method), !config.resolvedAllowRemoteWrite {
            reply(to: replyTo, corr: corr,
                  result: .error(code: -32003, message: "capability_denied: remote write disabled"))
            return
        }
        let ds = dataSource
        cmdQueue.async { [weak self] in
            let router = ControlRouter(dataSource: ds)
            let result = router.handle(method: method, params: params)
            self?.reply(to: replyTo, corr: corr, result: result)
        }
    }

    /// `{pane_id, limit, before_seq, reply_to, corr}` → reply from the per-pane
    /// JSONL buffer (`PaneHistoryBuffer`).
    private func handleHistory(_ env: [String: Any]) {
        let replyTo = env["reply_to"] as? String
        let corr = env["corr"] as? String
        let paneId = env["pane_id"] as? String ?? ""
        let limit = env["limit"] as? Int ?? 50
        let beforeSeq = env["before_seq"] as? Int
        let (messages, hasMore) = history.messages(paneId: paneId, limit: limit, beforeSeq: beforeSeq)
        reply(to: replyTo, corr: corr, result: .ok(["messages": messages, "has_more": hasMore]))
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

        // full retained snapshot so a client that connects while Mac is up (or
        // after) immediately has every pane/worktree + the single focus.
        publishFullSnapshot()
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        let topic = message.topic
        guard let payload = message.string, let env = decode(payload) else { return }
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
}

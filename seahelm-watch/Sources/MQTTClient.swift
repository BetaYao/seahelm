import Foundation

enum ConnState: Equatable { case disconnected, connecting, connected }

/// Minimal MQTT 3.1.1 client over a native `URLSessionWebSocketTask` — no
/// third-party dependency (CocoaMQTT's TCP socket doesn't build for watchOS).
/// Implements just what the watch needs: CONNECT/SUBSCRIBE/PUBLISH/PING + inbound
/// PUBLISH decode. QoS 0 throughout (retained state is still delivered on
/// subscribe). Speaks the §15 contract: retained pane/worktree/focus/presence/dnd
/// in, `command` / `history/request` out, replies via `reply/{clientId}/{corr}`.
final class MQTTClient: NSObject, URLSessionWebSocketDelegate {
    private let config: WatchConfig
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var rxBuffer = Data()
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var closed = false
    private var corrN = 0
    private var pending: [String: ([String: Any]) -> Void] = [:]

    // Event sinks (set by Store).
    var onState:    ((ConnState) -> Void)?
    var onPresence: ((Bool) -> Void)?
    var onDnd:      (([String: Any]) -> Void)?
    var onFocus:    (([String: Any]) -> Void)?
    var onPaneStatus: ((String, [String: Any]?) -> Void)?
    var onPaneEvent:  ((String, [String: Any]?) -> Void)?
    var onWorktree:   ((String, [String: Any]?) -> Void)?

    private var base: String { config.base }
    private var replyBase: String { "\(base)/reply/\(WatchConfig.clientId)" }

    init(config: WatchConfig) {
        self.config = config
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    // MARK: - Lifecycle

    func connect() {
        closed = false
        guard let url = URL(string: "\(config.tls ? "wss" : "ws")://\(config.host):\(config.port)\(config.wsPath)") else {
            deliver { self.onState?(.disconnected) }; return
        }
        deliver { self.onState?(.connecting) }
        let t = session.webSocketTask(with: url, protocols: ["mqtt"])
        task = t
        t.resume()
        // CONNECT once the socket opens (urlSession didOpenWithProtocol).
    }

    func disconnect() {
        closed = true
        pingTimer?.invalidate(); pingTimer = nil
        reconnectTimer?.invalidate(); reconnectTimer = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        deliver { self.onState?(.disconnected) }
    }

    private func scheduleReconnect() {
        guard !closed else { return }
        deliver { self.onState?(.disconnected) }
        DispatchQueue.main.async {
            self.reconnectTimer?.invalidate()
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                self?.connect()
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        rxBuffer.removeAll()
        sendPacket(MQTT.connect(clientId: WatchConfig.clientId, keepAlive: 45,
                                username: config.username, password: config.password))
        receiveLoop()
        DispatchQueue.main.async {
            self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.sendPacket(MQTT.pingReq())
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        scheduleReconnect()
    }

    // MARK: - Receive + parse

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.scheduleReconnect()
            case .success(let msg):
                switch msg {
                case .data(let d): self.rxBuffer.append(d)
                case .string(let s): self.rxBuffer.append(Data(s.utf8))
                @unknown default: break
                }
                self.drainPackets()
                self.receiveLoop()
            }
        }
    }

    /// Extract complete MQTT packets from `rxBuffer` and dispatch them.
    private func drainPackets() {
        while true {
            guard rxBuffer.count >= 2 else { return }
            let bytes = [UInt8](rxBuffer)
            let type = bytes[0] >> 4
            // decode remaining length (varint) starting at byte 1
            var mult = 1, value = 0, i = 1
            while true {
                guard i < bytes.count else { return }   // incomplete length
                let b = bytes[i]; value += Int(b & 0x7F) * mult
                i += 1
                if b & 0x80 == 0 { break }
                mult *= 128
                if mult > 128 * 128 * 128 { rxBuffer.removeAll(); return }
            }
            let total = i + value
            guard bytes.count >= total else { return }   // wait for more
            let packet = Array(bytes[i..<total])
            rxBuffer.removeSubrange(0..<total)
            handlePacket(type: type, header0: bytes[0], body: packet)
        }
    }

    private func handlePacket(type: UInt8, header0: UInt8, body: [UInt8]) {
        switch type {
        case 2:  // CONNACK
            let accepted = body.count >= 2 && body[1] == 0
            deliver { self.onState?(accepted ? .connected : .disconnected) }
            if accepted { subscribe("\(base)/#") }
        case 3:  // PUBLISH
            guard let (topic, payload) = MQTT.decodePublish(header0: header0, body: body) else { return }
            route(topic: topic, payload: payload)
        default: break   // SUBACK / PINGRESP / etc. ignored
        }
    }

    private func route(topic: String, payload: Data) {
        let raw = String(data: payload, encoding: .utf8) ?? ""
        let obj = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? nil
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

    private func subscribe(_ topic: String) {
        corrN += 1
        sendPacket(MQTT.subscribe(packetId: UInt16(truncatingIfNeeded: corrN), topic: topic))
    }
    private func publishJSON(_ topic: String, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        sendPacket(MQTT.publish(topic: topic, payload: data))
    }
    private func sendPacket(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }

    private func deliver(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }
}

// MARK: - MQTT 3.1.1 packet codec

private enum MQTT {
    static func varLen(_ n: Int) -> [UInt8] {
        var x = n, out: [UInt8] = []
        repeat { var b = UInt8(x % 128); x /= 128; if x > 0 { b |= 0x80 }; out.append(b) } while x > 0
        return out
    }
    static func str(_ s: String) -> [UInt8] {
        let b = Array(s.utf8); return [UInt8(b.count >> 8), UInt8(b.count & 0xFF)] + b
    }
    static func frame(_ type: UInt8, _ flags: UInt8, _ body: [UInt8]) -> Data {
        Data([(type << 4) | flags] + varLen(body.count) + body)
    }

    static func connect(clientId: String, keepAlive: UInt16, username: String?, password: String?) -> Data {
        var flags: UInt8 = 0x02   // clean session
        if username != nil { flags |= 0x80 }
        if password != nil { flags |= 0x40 }
        var body = str("MQTT") + [0x04, flags, UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)]
        body += str(clientId)
        if let u = username { body += str(u) }
        if let p = password { body += str(p) }
        return frame(1, 0, body)
    }
    static func subscribe(packetId: UInt16, topic: String) -> Data {
        let body = [UInt8(packetId >> 8), UInt8(packetId & 0xFF)] + str(topic) + [0x00] // QoS0
        return frame(8, 0x02, body)
    }
    static func publish(topic: String, payload: Data) -> Data {   // QoS0, no packet id
        frame(3, 0x00, str(topic) + [UInt8](payload))
    }
    static func pingReq() -> Data { Data([0xC0, 0x00]) }

    /// Decode an inbound PUBLISH → (topic, payload). QoS assumed 0 (no packet id).
    static func decodePublish(header0: UInt8, body: [UInt8]) -> (String, Data)? {
        guard body.count >= 2 else { return nil }
        let tlen = Int(body[0]) << 8 | Int(body[1])
        guard body.count >= 2 + tlen else { return nil }
        let topic = String(bytes: body[2..<(2 + tlen)], encoding: .utf8) ?? ""
        var idx = 2 + tlen
        let qos = (header0 >> 1) & 0x03
        if qos > 0, body.count >= idx + 2 { idx += 2 }   // skip packet id for QoS>0
        return (topic, Data(body[idx...]))
    }
}

import Foundation

/// WeCom smart bot channel — connects to enterprise WeChat via WebSocket long connection.
/// Pure protocol adapter: receives WeCom frames → translates to InboundMessage → forwards to AgentHead.
/// Outbound: OutboundMessage → WeCom frame → sends via WebSocket.
class WeComBotChannel: ExternalChannel {
    let channelId: String
    let channelType: ExternalChannelType = .wecom
    var onMessage: ((InboundMessage) -> Void)?

    private let config: WeComBotConfig
    private var stateMachine = GatewayStateMachine()
    private(set) var gatewayState: GatewayState = .disconnected

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectAttempt = 0
    private var reconnectTimer: Timer?

    /// Maps req_id → WeComFrame for passive replies (aibot_respond_msg needs original req_id)
    private var pendingReqIds: [String: String] = [:] // messageId → reqId
    private let lock = NSLock()

    /// Callback when gateway state changes
    var onStateChange: ((GatewayState) -> Void)?

    init(config: WeComBotConfig, channelId: String? = nil) {
        self.config = config
        self.channelId = channelId ?? "wecom-\(config.botId)"
    }

    deinit {
        disconnect()
    }

    // MARK: - ExternalChannel

    func connect() {
        guard stateMachine.transition(to: .connecting) else { return }
        gatewayState = stateMachine.state
        onStateChange?(gatewayState)
        reconnectAttempt = 0

        guard let url = URL(string: "wss://openws.work.weixin.qq.com") else {
            updateState(.error("Invalid WebSocket URL"))
            return
        }

        NSLog("[WeComBot] Connecting to \(url)")

        let session = URLSession(configuration: .default)
        urlSession = session
        let ws = session.webSocketTask(with: url)
        webSocket = ws
        ws.resume()

        // Send subscribe frame after connection
        authenticate()

        // Start listening
        receiveLoop()
    }

    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        updateState(.disconnected)
    }

    func send(_ message: OutboundMessage) {
        // Try passive reply first (if we have a pending req_id for this message)
        lock.lock()
        let reqId = pendingReqIds.removeValue(forKey: message.replyToMessageId ?? "")
        lock.unlock()

        let frameData: Data?
        if let reqId {
            frameData = WeComFrameParser.toRespondFrame(message, reqId: reqId)
        } else {
            frameData = WeComFrameParser.toSendFrame(message, botId: config.botId)
        }

        guard let data = frameData,
              let text = String(data: data, encoding: .utf8) else {
            NSLog("[WeComBot] Failed to build outbound frame")
            return
        }

        webSocket?.send(.string(text)) { error in
            if let error {
                NSLog("[WeComBot] Send error: \(error)")
            }
        }
    }

    // MARK: - Authentication

    private func authenticate() {
        guard let data = WeComFrameParser.subscribeFrame(botId: config.botId, secret: config.secret),
              let text = String(data: data, encoding: .utf8) else {
            updateState(.error("Failed to build subscribe frame"))
            return
        }

        webSocket?.send(.string(text)) { [weak self] error in
            if let error {
                NSLog("[WeComBot] Subscribe send error: \(error)")
                self?.updateState(.error(error.localizedDescription))
                return
            }
            NSLog("[WeComBot] Subscribe frame sent")
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self.handleFrame(data)
                    }
                case .data(let data):
                    self.handleFrame(data)
                @unknown default:
                    break
                }
                // Continue listening
                self.receiveLoop()

            case .failure(let error):
                // Don't treat cancellation as error
                if (error as NSError).code == 57 { return }
                NSLog("[WeComBot] Receive error: \(error)")
                self.updateState(.error(error.localizedDescription))
                self.scheduleReconnect()
            }
        }
    }

    // MARK: - Frame Handling

    private func handleFrame(_ data: Data) {
        guard let frame = WeComFrameParser.parse(data) else { return }

        switch frame.cmd {
        case "aibot_msg_callback":
            // Mark connected on first message
            if stateMachine.state == .connecting {
                updateState(.connected)
            }

            guard let inbound = WeComFrameParser.toInboundMessage(frame, channelId: channelId) else { return }

            // Store req_id for passive reply
            lock.lock()
            pendingReqIds[inbound.messageId] = frame.reqId
            // Keep map bounded
            if pendingReqIds.count > 100 {
                let oldest = pendingReqIds.keys.prefix(50)
                for key in oldest { pendingReqIds.removeValue(forKey: key) }
            }
            lock.unlock()

            onMessage?(inbound)

        case "aibot_event_callback":
            if stateMachine.state == .connecting {
                updateState(.connected)
            }
            let eventType = frame.body["event_type"] as? String ?? "unknown"
            NSLog("[WeComBot] Event: \(eventType)")

        default:
            if stateMachine.state == .connecting {
                updateState(.connected)
            }
            NSLog("[WeComBot] Frame: \(frame.cmd)")
        }
    }

    // MARK: - State & Reconnect

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
        let maxInterval = config.resolvedMaxReconnectInterval
        let delay = min(pow(2.0, Double(reconnectAttempt)), maxInterval)

        NSLog("[WeComBot] Scheduling reconnect in \(delay)s (attempt \(reconnectAttempt))")
        DispatchQueue.main.async { [weak self] in
            self?.reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.connect()
            }
        }
    }
}

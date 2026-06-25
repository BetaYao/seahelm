import Foundation

/// WeChat channel — connects to personal WeChat via iLink HTTP long-polling.
/// Uses getupdates for receiving messages, sendmessage for replies.
class WeChatChannel: ExternalChannel {
    let channelId: String
    let channelType: ExternalChannelType = .wechat
    var onMessage: ((InboundMessage) -> Void)?

    private var config: WeChatConfig
    private var stateMachine = GatewayStateMachine()
    private(set) var gatewayState: GatewayState = .disconnected

    private var isPolling = false
    private var shouldStop = false
    private var syncBuf: String = ""
    /// context_token per user — needed for sendmessage replies
    private var contextTokens: [String: String] = [:]
    private let lock = NSLock()
    private let session: URLSession

    private static let channelVersion = "0.1.0"
    private static let longPollTimeoutSec: TimeInterval = 40
    private static let maxConsecutiveFailures = 3
    private static let backoffDelaySec: TimeInterval = 30
    private static let retryDelaySec: TimeInterval = 2

    var onStateChange: ((GatewayState) -> Void)?

    init(config: WeChatConfig, channelId: String? = nil) {
        self.config = config
        self.channelId = channelId ?? "wechat-\(config.accountId ?? "default")"
        self.syncBuf = config.syncBuf ?? ""
        self.contextTokens = config.contextTokens ?? [:]

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = Self.longPollTimeoutSec + 5
        self.session = URLSession(configuration: sessionConfig)
    }

    deinit {
        disconnect()
    }

    // MARK: - ExternalChannel

    func connect() {
        guard stateMachine.transition(to: .connecting) else { return }
        gatewayState = stateMachine.state
        onStateChange?(gatewayState)
        shouldStop = false

        guard !config.botToken.isEmpty else {
            updateState(.error("bot_token is empty"))
            return
        }

        NSLog("[WeChat] Starting long-poll loop")
        updateState(.connected)
        startPolling()
    }

    func disconnect() {
        shouldStop = true
        updateState(.disconnected)
    }

    func send(_ message: OutboundMessage) {
        let userId = message.targetUserId ?? message.targetChatId ?? ""
        guard !userId.isEmpty else {
            NSLog("[WeChat] Cannot send: no target user ID")
            return
        }

        lock.lock()
        let contextToken = contextTokens[userId] ?? ""
        lock.unlock()

        sendTextMessage(toUserId: userId, text: message.content, contextToken: contextToken)
    }

    // MARK: - Long-Poll Loop

    private func startPolling() {
        guard !isPolling else { return }
        isPolling = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.pollLoop()
        }
    }

    private func pollLoop() {
        var consecutiveFailures = 0

        while !shouldStop {
            let (response, error) = syncGetUpdates()

            if let error {
                if error == "timeout" { continue }
                consecutiveFailures += 1
                NSLog("[WeChat] Poll error: \(error)")
                if consecutiveFailures >= Self.maxConsecutiveFailures {
                    updateState(.error(error))
                    consecutiveFailures = 0
                    Thread.sleep(forTimeInterval: Self.backoffDelaySec)
                } else {
                    Thread.sleep(forTimeInterval: Self.retryDelaySec)
                }
                continue
            }

            guard let response else { continue }

            if let apiError = response.apiError {
                consecutiveFailures += 1
                NSLog("[WeChat] API error: \(apiError)")

                if response.isAuthError {
                    updateState(.error("Token expired. Please re-authenticate."))
                    isPolling = false
                    return
                }

                if consecutiveFailures >= Self.maxConsecutiveFailures {
                    updateState(.error(apiError))
                    consecutiveFailures = 0
                    Thread.sleep(forTimeInterval: Self.backoffDelaySec)
                } else {
                    Thread.sleep(forTimeInterval: Self.retryDelaySec)
                }
                continue
            }

            consecutiveFailures = 0

            if let buf = response.getUpdatesBuf {
                syncBuf = buf
            }

            for msg in response.userMessages {
                processIncomingMessage(msg)
            }
        }

        isPolling = false
        NSLog("[WeChat] Poll loop ended")
    }

    // MARK: - HTTP: getupdates

    private func syncGetUpdates() -> (result: GetUpdatesResult?, error: String?) {
        let url = "\(config.resolvedBaseUrl)/ilink/bot/getupdates"
        guard let requestUrl = URL(string: url) else {
            return (nil, "Invalid URL")
        }

        var request = URLRequest(url: requestUrl)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.longPollTimeoutSec
        applyHeaders(&request)

        let body: [String: Any] = [
            "get_updates_buf": syncBuf,
            "base_info": ["channel_version": Self.channelVersion]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var parsedResult: GetUpdatesResult?
        var parsedError: String? = "no response"

        let task = session.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }

            if let error = error as NSError? {
                parsedError = error.code == NSURLErrorTimedOut ? "timeout" : error.localizedDescription
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                parsedError = "invalid response"
                return
            }

            parsedResult = GetUpdatesResult(json: json)
            parsedError = nil
        }
        task.resume()
        semaphore.wait()
        return (parsedResult, parsedError)
    }

    // MARK: - HTTP: sendmessage

    private func sendTextMessage(toUserId: String, text: String, contextToken: String) {
        let url = "\(config.resolvedBaseUrl)/ilink/bot/sendmessage"
        guard let requestUrl = URL(string: url) else { return }

        var request = URLRequest(url: requestUrl)
        request.httpMethod = "POST"
        applyHeaders(&request)

        let clientId = "amux:\(Int(Date().timeIntervalSince1970 * 1000))-\(UInt32.random(in: 0...UInt32.max))"
        let body: [String: Any] = [
            "msg": [
                "from_user_id": "",
                "to_user_id": toUserId,
                "client_id": clientId,
                "message_type": 2, // bot
                "message_state": 2, // finish
                "item_list": [["type": 1, "text_item": ["text": text]]],
                "context_token": contextToken,
            ],
            "base_info": ["channel_version": Self.channelVersion]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = session.dataTask(with: request) { _, response, error in
            if let error {
                NSLog("[WeChat] sendmessage error: \(error)")
                return
            }
            if let http = response as? HTTPURLResponse, !http.statusCode.isSuccessful {
                NSLog("[WeChat] sendmessage HTTP \(http.statusCode)")
            }
        }
        task.resume()
    }

    // MARK: - Message Processing

    private func processIncomingMessage(_ msg: ILinkUserMessage) {
        guard !msg.text.isEmpty else { return }

        // Cache context token
        if let ct = msg.contextToken, !ct.isEmpty {
            lock.lock()
            contextTokens[msg.senderId] = ct
            lock.unlock()
        }

        let inbound = InboundMessage(
            channelId: channelId,
            senderId: msg.senderId,
            senderName: msg.senderId,
            chatId: nil,
            chatType: .direct,
            content: msg.text,
            messageId: msg.clientId ?? UUID().uuidString,
            timestamp: Date(),
            replyTo: nil,
            metadata: nil
        )

        onMessage?(inbound)
    }

    // MARK: - Helpers

    private func applyHeaders(_ request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ilink_bot_token", forHTTPHeaderField: "AuthorizationType")
        request.setValue(randomWeChatUin(), forHTTPHeaderField: "X-WECHAT-UIN")
        if !config.botToken.isEmpty {
            request.setValue("Bearer \(config.botToken)", forHTTPHeaderField: "Authorization")
        }
    }

    private func randomWeChatUin() -> String {
        let value = UInt32.random(in: 0...UInt32.max)
        return Data(String(value).utf8).base64EncodedString()
    }

    private func updateState(_ newState: GatewayState) {
        guard stateMachine.transition(to: newState) else { return }
        gatewayState = stateMachine.state
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStateChange?(self.gatewayState)
        }
    }
}

// MARK: - HTTP Int Extension

private extension Int {
    var isSuccessful: Bool { (200..<300).contains(self) }
}

// MARK: - Response Parsing

private struct GetUpdatesResult {
    let getUpdatesBuf: String?
    let userMessages: [ILinkUserMessage]
    let apiError: String?
    let isAuthError: Bool

    init(json: [String: Any]) {
        getUpdatesBuf = json["get_updates_buf"] as? String

        let ret = json["ret"] as? Int ?? 0
        let errcode = json["errcode"] as? Int ?? 0
        let errmsg = json["errmsg"] as? String

        if ret != 0 || errcode != 0 {
            apiError = "ret=\(ret) errcode=\(errcode) errmsg=\(errmsg ?? "")"
            isAuthError = errcode == 401 || errcode == 403
        } else {
            apiError = nil
            isAuthError = false
        }

        var messages: [ILinkUserMessage] = []
        if let msgs = json["msgs"] as? [[String: Any]] {
            for msg in msgs {
                // Only process user messages (type 1)
                guard (msg["message_type"] as? Int) == 1 else { continue }

                let senderId = msg["from_user_id"] as? String ?? "unknown"
                let clientId = msg["client_id"] as? String
                let contextToken = msg["context_token"] as? String

                // Extract text from item_list
                var text = ""
                if let items = msg["item_list"] as? [[String: Any]] {
                    for item in items {
                        let itemType = item["type"] as? Int
                        if itemType == 1, // text
                           let textItem = item["text_item"] as? [String: Any],
                           let t = textItem["text"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty {
                            // Check for ref_msg (quoted reply)
                            if let refMsg = item["ref_msg"] as? [String: Any],
                               let title = refMsg["title"] as? String {
                                text = "[引用: \(title)]\n\(t.trimmingCharacters(in: .whitespaces))"
                            } else {
                                text = t.trimmingCharacters(in: .whitespaces)
                            }
                            break
                        }
                        if itemType == 3, // voice
                           let voiceItem = item["voice_item"] as? [String: Any],
                           let t = voiceItem["text"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty {
                            text = t.trimmingCharacters(in: .whitespaces)
                            break
                        }
                        // Fallback: try text_item without type check
                        if let textItem = item["text_item"] as? [String: Any],
                           let t = textItem["text"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty, text.isEmpty {
                            text = t.trimmingCharacters(in: .whitespaces)
                        }
                    }
                }

                if !text.isEmpty {
                    messages.append(ILinkUserMessage(
                        senderId: senderId,
                        text: text,
                        clientId: clientId,
                        contextToken: contextToken
                    ))
                }
            }
        }
        userMessages = messages
    }
}

private struct ILinkUserMessage {
    let senderId: String
    let text: String
    let clientId: String?
    let contextToken: String?
}

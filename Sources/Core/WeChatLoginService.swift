import Foundation

/// Result of a completed iLink QR login.
struct WeChatLoginResult {
    let botToken: String
    let accountId: String
    /// Server-assigned API host for subsequent traffic; nil means keep the default.
    let baseUrl: String?
    /// The user who scanned the code.
    let userId: String?
}

/// Drives the iLink QR bind flow: fetch a code, long-poll its status until the
/// user confirms on their phone.
///
/// Runs its loop on a background queue; all events are delivered on the main queue.
class WeChatLoginService {
    enum Event {
        /// A code is ready to display. The payload is the URL the QR should encode.
        case qrCode(String)
        /// Phone scanned the code, waiting for the user to confirm.
        case scanned
        /// The server wants the pairing digits shown on the phone.
        /// `retry` is true when a previous submission was rejected.
        case needVerifyCode(retry: Bool)
        /// This account is already bound to this app — nothing to do.
        case alreadyBound
        case succeeded(WeChatLoginResult)
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?

    private static let apiBaseUrl = "https://ilinkai.weixin.qq.com"
    private static let botType = "3"
    private static let appId = "bot"
    /// uint32 as 0x00MMNNPP — major<<16 | minor<<8 | patch
    private static let appClientVersion = 0 << 16 | 1 << 8 | 0  // 0.1.0
    private static let statusLongPollTimeoutSec: TimeInterval = 35
    private static let fetchTimeoutSec: TimeInterval = 20
    private static let pollIntervalSec: TimeInterval = 1
    private static let overallTimeoutSec: TimeInterval = 480
    private static let maxQRRefreshCount = 3

    /// Existing tokens are sent with the code request so the server can recognise
    /// a re-bind of an account we already hold.
    private let localBotTokens: [String]

    private let session: URLSession
    private let lock = NSLock()
    private var shouldStop = false

    /// Guards `pendingVerifyCode` handoff from the UI thread to the poll loop.
    private let verifyCondition = NSCondition()
    private var pendingVerifyCode: String?
    private var awaitingVerifyCode = false

    /// Effective polling host — may move on an IDC redirect.
    private var currentBaseUrl: String

    init(existingBotTokens: [String] = []) {
        self.localBotTokens = existingBotTokens
        self.currentBaseUrl = Self.apiBaseUrl

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = Self.statusLongPollTimeoutSec + 5
        self.session = URLSession(configuration: sessionConfig)
    }

    deinit {
        cancel()
    }

    // MARK: - Control

    func start() {
        lock.lock()
        shouldStop = false
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runLoginFlow()
        }
    }

    func cancel() {
        lock.lock()
        shouldStop = true
        lock.unlock()

        // Release the loop if it is parked waiting for pairing digits.
        verifyCondition.lock()
        verifyCondition.broadcast()
        verifyCondition.unlock()
    }

    /// Hand pairing digits to the poll loop. Call after `.needVerifyCode`.
    func submitVerifyCode(_ code: String) {
        verifyCondition.lock()
        pendingVerifyCode = code
        awaitingVerifyCode = false
        verifyCondition.signal()
        verifyCondition.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shouldStop
    }

    // MARK: - Flow

    private func runLoginFlow() {
        guard var qrcode = fetchQRCodeEmittingEvents() else { return }

        let deadline = Date().addingTimeInterval(Self.overallTimeoutSec)
        var qrRefreshCount = 1
        var scannedEmitted = false
        var verifyCodeRejected = false

        while !isStopped && Date() < deadline {
            let submitCode = takePendingVerifyCode()
            guard let status = pollStatus(qrcode: qrcode, verifyCode: submitCode) else {
                emit(.failed("Login failed: could not reach the WeChat server."))
                return
            }

            switch status.status {
            case "wait":
                break

            case "scaned":
                // Reaching `scaned` while a code was in flight means it was accepted.
                verifyCodeRejected = false
                if !scannedEmitted {
                    scannedEmitted = true
                    emit(.scanned)
                }

            case "need_verifycode":
                emit(.needVerifyCode(retry: verifyCodeRejected))
                verifyCodeRejected = true
                guard waitForVerifyCode() else { return }
                continue  // poll immediately, don't idle a second first

            case "scaned_but_redirect":
                if let host = status.redirectHost, !host.isEmpty {
                    currentBaseUrl = "https://\(host)"
                    NSLog("[WeChatLogin] IDC redirect, polling host is now \(host)")
                } else {
                    NSLog("[WeChatLogin] scaned_but_redirect without redirect_host, staying put")
                }

            case "expired", "verify_code_blocked":
                if status.status == "verify_code_blocked" {
                    clearPendingVerifyCode()
                    verifyCodeRejected = false
                }
                qrRefreshCount += 1
                guard qrRefreshCount <= Self.maxQRRefreshCount else {
                    emit(.failed(status.status == "verify_code_blocked"
                        ? "Too many incorrect codes. Please try again later."
                        : "The QR code expired too many times. Please try again."))
                    return
                }
                guard let refreshed = fetchQRCodeEmittingEvents() else { return }
                qrcode = refreshed
                scannedEmitted = false

            case "binded_redirect":
                emit(.alreadyBound)
                return

            case "confirmed":
                guard let accountId = status.botId, !accountId.isEmpty,
                      let botToken = status.botToken, !botToken.isEmpty else {
                    emit(.failed("Login confirmed but the server returned no credentials."))
                    return
                }
                emit(.succeeded(WeChatLoginResult(
                    botToken: botToken,
                    accountId: accountId,
                    baseUrl: status.baseUrl,
                    userId: status.userId
                )))
                return

            default:
                NSLog("[WeChatLogin] Unknown status: \(status.status)")
            }

            Thread.sleep(forTimeInterval: Self.pollIntervalSec)
        }

        guard !isStopped else { return }
        emit(.failed("Timed out waiting for the QR code to be scanned."))
    }

    /// Fetch a code and emit it for display. Returns the polling token, or nil on failure.
    private func fetchQRCodeEmittingEvents() -> String? {
        let (response, error) = fetchQRCode()
        guard let response else {
            emit(.failed(error ?? "Could not get a QR code from WeChat."))
            return nil
        }
        emit(.qrCode(response.imageContent))
        return response.qrcode
    }

    // MARK: - Verify code handoff

    private func takePendingVerifyCode() -> String? {
        verifyCondition.lock()
        defer { verifyCondition.unlock() }
        let code = pendingVerifyCode
        pendingVerifyCode = nil
        return code
    }

    private func clearPendingVerifyCode() {
        verifyCondition.lock()
        pendingVerifyCode = nil
        verifyCondition.unlock()
    }

    /// Block until `submitVerifyCode` supplies digits. Returns false if cancelled.
    private func waitForVerifyCode() -> Bool {
        verifyCondition.lock()
        awaitingVerifyCode = true
        while awaitingVerifyCode && !isStopped {
            verifyCondition.wait(until: Date().addingTimeInterval(1))
        }
        let cancelled = isStopped
        awaitingVerifyCode = false
        verifyCondition.unlock()
        return !cancelled
    }

    // MARK: - HTTP: get_bot_qrcode

    private func fetchQRCode() -> (response: QRCodeResponse?, error: String?) {
        let endpoint = "\(Self.apiBaseUrl)/ilink/bot/get_bot_qrcode?bot_type=\(Self.botType)"
        guard let url = URL(string: endpoint) else {
            return (nil, "Invalid QR code URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.fetchTimeoutSec
        applyHeaders(&request)
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["local_token_list": localBotTokens]
        )

        let semaphore = DispatchSemaphore(value: 0)
        var parsedResponse: QRCodeResponse?
        var parsedError: String? = "No response from server"

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error {
                parsedError = "Could not reach WeChat: \(error.localizedDescription)"
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                parsedError = "WeChat server returned HTTP \(http.statusCode)"
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let qrcode = json["qrcode"] as? String,
                  let imageContent = json["qrcode_img_content"] as? String,
                  !qrcode.isEmpty, !imageContent.isEmpty else {
                parsedError = "WeChat server returned an unreadable QR code"
                return
            }
            parsedResponse = QRCodeResponse(qrcode: qrcode, imageContent: imageContent)
            parsedError = nil
        }
        task.resume()
        semaphore.wait()
        return (parsedResponse, parsedError)
    }

    // MARK: - HTTP: get_qrcode_status

    /// Long-poll the code's status. Network hiccups and gateway timeouts map to
    /// `wait` so the caller keeps polling, matching the reference client.
    private func pollStatus(qrcode: String, verifyCode: String?) -> QRStatusResponse? {
        guard let encodedQrcode = qrcode.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) else {
            return nil
        }
        var endpoint = "\(currentBaseUrl)/ilink/bot/get_qrcode_status?qrcode=\(encodedQrcode)"
        if let verifyCode,
           let encodedCode = verifyCode.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) {
            endpoint += "&verify_code=\(encodedCode)"
        }
        guard let url = URL(string: endpoint) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.statusLongPollTimeoutSec
        applyHeaders(&request)

        let semaphore = DispatchSemaphore(value: 0)
        var result: QRStatusResponse? = QRStatusResponse(status: "wait")

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if error != nil {
                return  // treat as `wait` and retry
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                NSLog("[WeChatLogin] get_qrcode_status HTTP \(http.statusCode), retrying")
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String else {
                NSLog("[WeChatLogin] get_qrcode_status returned an unreadable body, retrying")
                return
            }
            result = QRStatusResponse(
                status: status,
                botToken: json["bot_token"] as? String,
                botId: json["ilink_bot_id"] as? String,
                baseUrl: json["baseurl"] as? String,
                userId: json["ilink_user_id"] as? String,
                redirectHost: json["redirect_host"] as? String
            )
        }
        task.resume()
        semaphore.wait()
        return result
    }

    // MARK: - Helpers

    private func applyHeaders(_ request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ilink_bot_token", forHTTPHeaderField: "AuthorizationType")
        request.setValue(Self.appId, forHTTPHeaderField: "iLink-App-Id")
        request.setValue(String(Self.appClientVersion), forHTTPHeaderField: "iLink-App-ClientVersion")
        request.setValue(randomWeChatUin(), forHTTPHeaderField: "X-WECHAT-UIN")
    }

    private func randomWeChatUin() -> String {
        let value = UInt32.random(in: 0...UInt32.max)
        return Data(String(value).utf8).base64EncodedString()
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}

// MARK: - Response Types

private struct QRCodeResponse {
    let qrcode: String
    /// URL the QR image should encode.
    let imageContent: String
}

private struct QRStatusResponse {
    let status: String
    var botToken: String?
    var botId: String?
    var baseUrl: String?
    var userId: String?
    var redirectHost: String?
}

private extension CharacterSet {
    /// `urlQueryAllowed` still permits `&` and `=`, which would break a value.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?")
        return set
    }()
}

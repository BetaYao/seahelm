import Foundation

enum GmailMailClientError: Error, Equatable {
    case authorizationExpired
    /// Gmail returns 404 when a history cursor has aged out. This is deliberately
    /// not a signal to scan the inbox: the channel starts a fresh window instead.
    case historyExpired
    case transport(String)
    case malformedResponse
}

struct GmailMailPoll: Equatable {
    var messages: [GmailInboundMessage]
    var latestHistoryId: String?
}

/// The narrow seam between mail policy and Google REST. A fake supplies this in
/// tests; callers never handle OAuth headers, pagination, or Gmail JSON.
protocol GmailMailClient {
    func poll(since: Date, historyID: String?, inboundAlias: String,
              completion: @escaping (Result<GmailMailPoll, GmailMailClientError>) -> Void)
}

/// Owns the application-lifetime polling window. It never scans before `start`;
/// a restart and a history expiration both establish a new "now" boundary.
final class GmailMailPoller {
    var onAcceptedMessage: ((GmailInboundMessage) -> Void)?
    var onStateChange: ((GmailMailAuditCode) -> Void)?

    private let client: GmailMailClient
    private let stateStore: GmailMailStateStore
    private let queue = DispatchQueue(label: "seahelm.gmail-mail-poller", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var config: GmailMailConfig?
    private var state: GmailMailState?
    private var polling = false

    init(client: GmailMailClient, stateStore: GmailMailStateStore = GmailMailStateStore()) {
        self.client = client
        self.stateStore = stateStore
    }

    func start(config: GmailMailConfig, now: Date = Date()) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            guard config.enabled, config.validationError == nil else { return }
            // Intentionally discard an old persisted cursor: old/offline mail must
            // never become eligible merely because Seahelm was relaunched.
            self.config = config
            self.state = GmailMailState(syncStartedAt: now)
            try? self.stateStore.save(self.state!)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: config.resolvedPollIntervalSeconds)
            timer.setEventHandler { [weak self] in self?.pollLocked() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() { queue.async { [weak self] in self?.stopLocked() } }

    private func stopLocked() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        config = nil
        state = nil
        polling = false
    }

    private func pollLocked() {
        guard !polling, let config, let state else { return }
        polling = true
        client.poll(since: state.syncStartedAt, historyID: state.latestHistoryId, inboundAlias: config.inboundAlias) { [weak self] result in
            self?.queue.async {
                guard let self else { return }
                self.polling = false
                guard var state = self.state, let config = self.config else { return }
                switch result {
                case .success(let poll):
                    state.latestHistoryId = poll.latestHistoryId ?? state.latestHistoryId
                    for message in poll.messages {
                        let decision = GmailInboundValidator.validate(message, config: config,
                                                                      syncStartedAt: state.syncStartedAt,
                                                                      processedIDs: Set(state.processedMessageIDs))
                        switch decision {
                        case .accept:
                            // Deduplicate before invoking a caller that might create UI.
                            state.record(messageID: message.id, threadID: message.threadId, code: .accepted)
                            self.onAcceptedMessage?(message)
                        case .reject(let code):
                            // Name the address only when it is the reason, so an
                            // unusable whitelist can actually be fixed.
                            let sender = (code == .invalidSender || code == .unauthenticatedSender)
                                ? GmailInboundValidator.senderAddress(of: message) : nil
                            state.record(messageID: message.id, threadID: message.threadId,
                                         sender: sender, code: code)
                        }
                    }
                    self.state = state
                    try? self.stateStore.save(state)
                case .failure(.historyExpired):
                    // A new current window is safe; a full inbox recovery is not.
                    state = GmailMailState(syncStartedAt: Date())
                    state.record(messageID: "", threadID: "", code: .cursorReset)
                    self.state = state
                    try? self.stateStore.save(state)
                    self.onStateChange?(.cursorReset)
                case .failure(.authorizationExpired):
                    // Do not spin on an invalid grant or replay anything after a
                    // reconnect. A fresh explicit enable establishes a new window.
                    self.stopLocked()
                    self.onStateChange?(.authorizationExpired)
                case .failure:
                    self.onStateChange?(.clientError)
                }
            }
        }
    }
}

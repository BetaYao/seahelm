import Foundation

/// One live line per pane, in the chats that are talking to it: what the agent
/// is doing *while* it does it.
///
/// Telegram has no streaming primitive, and there is nothing token-shaped to
/// stream anyway — the agent's own prose reaches us once, whole, when the turn
/// ends. What we do have is every tool call as it happens (`PostToolUse`), and
/// that is the useful thing on a phone: not the words, but whether it is still
/// working and on what.
///
/// So this is one message, sent late, edited in place, and taken back when the
/// turn ends. It never carries the answer — the completion notice does, exactly
/// as before, as its own message. That separation is deliberate: the progress
/// line is disposable, and anything the reader needs to keep must not be.
///
/// Three rules keep it from becoming the noisiest thing in the chat:
///
///   - **Only bound chats.** A `/go #n` conversation asked to watch this pane.
///     A fleet listener did not, and a live line per pane across a fleet is a
///     chat nobody can read.
///   - **Late.** A turn that ends in seconds would post and delete a message
///     for nothing. Nothing appears until `graceSeconds` of work have passed.
///   - **Throttled.** An edit at most every `minEditInterval`, and never one
///     that would put up the same words — Telegram answers both with an error,
///     and it would be right to.
final class ChatProgressReporter {

    /// Sending is asynchronous and the id comes back late; everything else
    /// needs that id. Owner-supplied so the reporter can be tested without a
    /// live bridge.
    ///
    /// All three, and `ingest`, run on the main thread — the outcome stream is
    /// already there. The owner is responsible for hopping the send's reply
    /// back, since a bridge answers from a queue of its own.
    var send: ((_ chatId: String, _ text: String, _ done: @escaping (String?) -> Void) -> Void)?
    var edit: ((_ chatId: String, _ messageId: String, _ text: String) -> Void)?
    var remove: ((_ chatId: String, _ messageId: String) -> Void)?

    private struct Line {
        var messageId: String?
        /// Set while a send is in flight, so a burst of tool calls cannot post
        /// the same line twice.
        var sending = false
        var text = ""
        var editedAt = Date.distantPast
    }

    /// The pane's identity for this report: the key its bound chats are filed
    /// under, and the `#n` a reader recognises it by. Both come from the pane's
    /// Station, which a unit test cannot build — hence the seam.
    var identify: (PaneInfo) -> (key: String, handle: Int)? = { info in
        let sessionKey = info.station?.paneSessionKey ?? ""
        guard !sessionKey.isEmpty else { return nil }
        let key = PaneHandleRegistry.key(sessionKey: sessionKey, paneId: info.id)
        return (key, PaneHandleRegistry.shared.handle(for: key))
    }

    /// Keyed by pane handle key, then chat id.
    private var lines: [String: [String: Line]] = [:]
    /// When the turn now running on each pane began.
    private var turnStartedAt: [String: Date] = [:]
    private let sessions: CommandSessionStore

    init(sessions: CommandSessionStore) {
        self.sessions = sessions
    }

    /// How long a turn must have been running before it is worth a message.
    static let graceSeconds: TimeInterval = 12
    /// Telegram allows about one message a second per chat, and the notices
    /// that matter share that budget.
    static let minEditInterval: TimeInterval = 3

    // MARK: - Ingest

    func ingest(_ outcome: IngestOutcome, now: Date = Date()) {
        guard let (paneKey, handle) = identify(outcome.info) else { return }

        if Self.endsTurn(outcome) {
            turnStartedAt[paneKey] = nil
            clear(paneKey: paneKey)
            return
        }

        if turnStartedAt[paneKey] == nil { turnStartedAt[paneKey] = now }
        // A turn is only worth reporting once it has lasted; until then the
        // completion notice will beat us to it.
        guard let started = turnStartedAt[paneKey],
              now.timeIntervalSince(started) >= Self.graceSeconds else { return }

        let chats = chatIds(forPane: paneKey)
        guard !chats.isEmpty else { return }

        let text = Self.line(for: outcome.info, handle: handle, since: started, now: now)
        for chatId in chats { post(text, paneKey: paneKey, chatId: chatId, now: now) }
    }

    /// Every chat whose conversation is bound to this pane. A fleet listener is
    /// deliberately not one of them.
    private func chatIds(forPane paneKey: String) -> [String] {
        sessions.sessions(boundToPaneKey: paneKey)
            .filter { $0.surface == "telegram" }
            .map(\.id)
    }

    private func post(_ text: String, paneKey: String, chatId: String, now: Date) {
        var line = lines[paneKey]?[chatId] ?? Line()
        guard !line.sending else { return }

        guard let messageId = line.messageId else {
            line.sending = true
            line.text = text
            // The send *is* the first paint: without this the next tool call,
            // a second later, would edit a message that has only just landed.
            line.editedAt = now
            lines[paneKey, default: [:]][chatId] = line
            send?(chatId, text) { [weak self] id in
                guard let self else { return }
                // The turn may have ended while this was in flight; a line
                // whose pane has since been cleared must not be left behind.
                guard var pending = self.lines[paneKey]?[chatId] else {
                    if let id { self.remove?(chatId, id) }
                    return
                }
                pending.sending = false
                pending.messageId = id
                self.lines[paneKey, default: [:]][chatId] = pending
            }
            return
        }

        guard text != line.text,
              now.timeIntervalSince(line.editedAt) >= Self.minEditInterval else { return }
        line.text = text
        line.editedAt = now
        lines[paneKey, default: [:]][chatId] = line
        edit?(chatId, messageId, text)
    }

    private func clear(paneKey: String) {
        guard let open = lines.removeValue(forKey: paneKey) else { return }
        for (chatId, line) in open {
            guard let messageId = line.messageId else { continue }
            remove?(chatId, messageId)
        }
    }

    // MARK: - Pure

    /// Whether this outcome ends the turn the line is reporting on.
    ///
    /// Every way a turn can stop counts, not just a clean finish: an agent that
    /// errored or is waiting on a question is no longer working, and leaving
    /// "running Bash" over a question is worse than saying nothing at all.
    static func endsTurn(_ outcome: IngestOutcome) -> Bool {
        if outcome.isCompletionSignal { return true }
        guard outcome.statusChanged else { return false }
        return outcome.newStatus == .idle || outcome.newStatus == .waiting || outcome.newStatus == .error
    }

    /// The line itself: which pane, what it is doing, how long it has been at
    /// it. Two rows, because a phone shows two before it truncates.
    static func line(for info: PaneInfo, handle: Int, since: Date, now: Date) -> String {
        let target = "#\(handle) \(info.project)/\(info.branch)"
        let elapsed = Self.elapsed(now.timeIntervalSince(since))
        guard let latest = info.activityEvents.first else {
            return "⏳ **\(target)** · \(elapsed)"
        }
        let detail = latest.detail.isEmpty ? latest.tool : "\(latest.tool) — \(latest.detail)"
        return "⏳ **\(target)** · \(elapsed)\n\(truncated(detail))"
    }

    /// Whole units only. A status line that ticks over a decimal redraws for a
    /// change nobody reads, and every redraw is a message edit.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        if whole < 60 { return "\(whole)s" }
        let minutes = whole / 60
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h\(minutes % 60)m"
    }

    static func truncated(_ text: String, limit: Int = 120) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count <= limit ? flat : "\(flat.prefix(limit - 1))…"
    }
}

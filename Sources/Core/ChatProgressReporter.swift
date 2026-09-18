import Foundation

/// One live line per pane, in the chats that are talking to it: what the agent
/// is doing *while* it does it.
///
/// Telegram has no streaming primitive, so this is one message, sent late,
/// edited in place, and taken back when the turn ends. Under the pane's name it
/// shows the last few rows of the pane's MessageStream — what the agent said
/// between tool calls, and the calls — the same timeline the web client reads,
/// cut to what a phone shows at a glance. A pane the stream has nothing for yet
/// (no hooks, or before its first row) shows its latest scanned activity.
///
/// It never carries the answer — the completion notice does, as its own
/// message. That separation is deliberate: the progress line is disposable,
/// and anything the reader needs to keep must not be.
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
    /// Runs `work` once `delay` has passed, with the time it ran. An edit held
    /// back by the throttle is put up when the interval is over — otherwise the
    /// row that starts a long build waits for whatever the build does next.
    var schedule: (_ delay: TimeInterval, _ work: @escaping (Date) -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work(Date()) }
    }

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
    /// The pane as its latest outcome left it, and its handle — what a stream
    /// row arriving between outcomes is reported under.
    private var panes: [String: (info: PaneInfo, handle: Int)] = [:]
    /// This turn's stream rows per pane, oldest first, at most `feedRows`.
    private var feeds: [String: [String]] = [:]
    /// Panes with a held-back edit already scheduled.
    private var flushing: Set<String> = []
    private let sessions: CommandSessionStore

    init(sessions: CommandSessionStore) {
        self.sessions = sessions
    }

    /// How long a turn must have been running before it is worth a message.
    static let graceSeconds: TimeInterval = 12
    /// Telegram allows about one message a second per chat, and the notices
    /// that matter share that budget.
    static let minEditInterval: TimeInterval = 3
    /// Rows under the pane's name — about what a phone shows without scrolling.
    static let feedRows = 6

    // MARK: - Ingest

    func ingest(_ outcome: IngestOutcome, now: Date = Date()) {
        guard let (paneKey, handle) = identify(outcome.info) else { return }

        if Self.endsTurn(outcome) {
            turnStartedAt[paneKey] = nil
            panes[paneKey] = nil
            feeds[paneKey] = nil
            clear(paneKey: paneKey)
            return
        }

        if turnStartedAt[paneKey] == nil {
            turnStartedAt[paneKey] = now
            feeds[paneKey] = []
        }
        panes[paneKey] = (outcome.info, handle)
        report(paneKey: paneKey, now: now)
    }

    /// A row of the pane's MessageStream. Only a turn this reporter has seen
    /// start takes rows, so the reply that closed the last turn — streamed
    /// after its Stop — never opens the next one.
    func ingest(_ message: MessageEvent, now: Date = Date()) {
        guard !message.paneSessionKey.isEmpty else { return }
        let paneKey = PaneHandleRegistry.key(sessionKey: message.paneSessionKey, paneId: message.paneId)
        guard turnStartedAt[paneKey] != nil, let row = Self.row(for: message) else { return }
        var feed = feeds[paneKey] ?? []
        feed.append(row)
        feeds[paneKey] = Array(feed.suffix(Self.feedRows))
        report(paneKey: paneKey, now: now)
    }

    private func report(paneKey: String, now: Date) {
        // A turn is only worth reporting once it has lasted; until then the
        // completion notice will beat us to it.
        guard let started = turnStartedAt[paneKey],
              now.timeIntervalSince(started) >= Self.graceSeconds,
              let pane = panes[paneKey] else { return }

        let chats = chatIds(forPane: paneKey)
        guard !chats.isEmpty else { return }

        let text = Self.line(for: pane.info, handle: pane.handle, feed: feeds[paneKey] ?? [],
                             since: started, now: now)
        var heldBack = false
        for chatId in chats {
            if !post(text, paneKey: paneKey, chatId: chatId, now: now) { heldBack = true }
        }
        guard heldBack, !flushing.contains(paneKey) else { return }
        flushing.insert(paneKey)
        schedule(Self.minEditInterval) { [weak self] ranAt in
            guard let self else { return }
            self.flushing.remove(paneKey)
            self.report(paneKey: paneKey, now: ranAt)
        }
    }

    /// Every chat whose conversation is bound to this pane. A fleet listener is
    /// deliberately not one of them.
    private func chatIds(forPane paneKey: String) -> [String] {
        sessions.telegramChats(boundToPaneKey: paneKey)
    }

    /// Puts `text` up in `chatId`. False when the throttle held a changed line
    /// back, so the caller can try again once the interval is over.
    @discardableResult
    private func post(_ text: String, paneKey: String, chatId: String, now: Date) -> Bool {
        var line = lines[paneKey]?[chatId] ?? Line()
        // Newer words than the send in flight are held back like a throttled edit.
        guard !line.sending else { return text == line.text }

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
            return true
        }

        guard text != line.text else { return true }
        guard now.timeIntervalSince(line.editedAt) >= Self.minEditInterval else { return false }
        line.text = text
        line.editedAt = now
        lines[paneKey, default: [:]][chatId] = line
        edit?(chatId, messageId, text)
        return true
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

    /// The line itself: which pane and for how long, then what it has been
    /// saying and doing — this turn's stream rows, or with none yet, the
    /// latest activity the screen showed.
    static func line(for info: PaneInfo, handle: Int, feed: [String] = [],
                     since: Date, now: Date) -> String {
        let head = "⏳ **#\(handle) \(info.project)/\(info.branch)** · \(elapsed(now.timeIntervalSince(since)))"
        if !feed.isEmpty { return head + "\n\n" + feed.joined(separator: "\n") }
        guard let latest = info.activityEvents.first else { return head }
        let detail = latest.detail.isEmpty ? latest.tool : "\(latest.tool) — \(latest.detail)"
        return "\(head)\n\(truncated(detail))"
    }

    /// One stream row as a line of the message. What the agent says reads as
    /// prose; a tool call is marked, kept short, and flagged when it failed.
    /// The rest of the stream — your own prompt, status edges, decisions — has
    /// its own messages in the chat already.
    static func row(for message: MessageEvent) -> String? {
        switch message.kind {
        case .assistant, .thinking:
            let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : truncated(text, limit: 200)
        case .tool:
            guard let tool = message.tool, !tool.isEmpty else { return nil }
            let detail = message.detail ?? ""
            let mark = message.isError == true ? "✗" : "›"
            return truncated(detail.isEmpty ? "\(mark) \(tool)" : "\(mark) \(tool) — \(detail)", limit: 100)
        case .user, .status, .decision, .notice:
            return nil
        }
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

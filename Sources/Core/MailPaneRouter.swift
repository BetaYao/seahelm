import Foundation

struct EmailConversation: Codable, Equatable {
    let gmailThreadID: String
    let paneSessionKey: String
    let paneID: String
    let projectAlias: String
    let worktreePath: String
    var closed: Bool
    /// Who bound this thread. Optional so conversations stored before the sender
    /// whitelist existed still decode; nil falls back to the Gmail account.
    var commander: String?
}

final class EmailConversationStore {
    private let url: URL
    private let queue = DispatchQueue(label: "seahelm.email-conversations")
    private var conversations: [String: EmailConversation] = [:]

    init(url: URL = Config.configDir.appendingPathComponent("gmail-mail-conversations.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let loaded = try? JSONDecoder().decode([String: EmailConversation].self, from: data) { conversations = loaded }
    }
    func conversation(for threadID: String) -> EmailConversation? { queue.sync { conversations[threadID] } }
    func conversation(forPaneSessionKey key: String) -> EmailConversation? { queue.sync { conversations.values.first { $0.paneSessionKey == key } } }
    func save(_ conversation: EmailConversation) { queue.sync { conversations[conversation.gmailThreadID] = conversation; persist() } }
    func close(paneSessionKey: String) { queue.sync { for (key, value) in conversations where value.paneSessionKey == paneSessionKey { var changed = value; changed.closed = true; conversations[key] = changed }; persist() } }
    @discardableResult func close(paneID: String) -> EmailConversation? { queue.sync {
        guard let key = conversations.first(where: { $0.value.paneID == paneID })?.key, var value = conversations[key] else { return nil }
        value.closed = true; conversations[key] = value; persist(); return value
    } }
    private func persist() { try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try? JSONEncoder().encode(conversations).write(to: url, options: .atomic) }
}

/// What one command turned out to mean for a mail thread.
enum MailCommandResult: Equatable {
    /// Answered; nothing about the thread changes.
    case reply(String)
    /// `/pane <n>` — answered, and this thread now steers that pane.
    case bind(paneID: String, sessionKey: String, worktreePath: String, reply: String)
}

/// Runs a command through the grammar the Helm line and iMessage already speak.
///
/// Mail owns no verbs of its own: the implementation parses with
/// `BridgeCommandParser` and renders with `BridgeCommandFormatter`, so the three
/// surfaces cannot drift. Only the *binding* is mail's own, because "the pane I
/// am talking to" is a thread here and a focused pane on the desktop.
///
/// Called on the main thread — `MailPaneRouter` hops — because it walks ShipLog.
protocol MailCommandContext: AnyObject {
    func interpret(_ text: String) -> MailCommandResult?
    /// Prose in a thread that never ran `/pane <n>`. Goes wherever iMessage's
    /// bare prose goes, so mail needs no setup to be useful. Nil when nothing
    /// is current to steer.
    func steerCurrent(_ text: String) -> String?
}

/// Serializes one Gmail thread, uses no focus state, and has exactly one input
/// side effect: the existing ControlDataSource submit path.
final class MailPaneRouter {
    enum Outcome: Equatable { case created; case delivered; case answered; case rejected(String) }
    var onOutcome: ((Outcome) -> Void)?
    /// Replies in-thread. `(body, threadID, inboundSubject, replyTo)`.
    var onReply: ((String, String, String, String) -> Void)?
    weak var commandContext: MailCommandContext?
    private let control: ControlDataSource
    private let store: EmailConversationStore
    private let attachmentStore: EmailAttachmentStore
    private let attachmentAccount: String?
    private let queue = DispatchQueue(label: "seahelm.gmail-mail-router")
    private var threadQueues: [String: DispatchQueue] = [:]

    init(control: ControlDataSource, store: EmailConversationStore = EmailConversationStore(),
         attachmentStore: EmailAttachmentStore = EmailAttachmentStore(), accountEmail: String? = nil) {
        self.control = control; self.store = store; self.attachmentStore = attachmentStore; self.attachmentAccount = accountEmail
    }

    func route(message: GmailInboundMessage, text: String) {
        queue.sync { if threadQueues[message.threadId] == nil { threadQueues[message.threadId] = DispatchQueue(label: "seahelm.gmail-thread.\(message.threadId)") } }
        threadQueues[message.threadId]?.async { [weak self] in self?.routeSerial(message: message, text: text) }
    }

    @discardableResult func close(paneID: String) -> EmailConversation? { store.close(paneID: paneID) }

    private func routeSerial(message: GmailInboundMessage, text: String) {
        if !message.attachments.isEmpty, let attachmentAccount {
            do { _ = try attachmentStore.importAttachments(message.attachments, account: attachmentAccount, threadID: message.threadId, messageID: message.id, limit: 20 * 1_024 * 1_024) }
            catch { onOutcome?(.rejected("attachment_rejected")); return }
        }
        // A reply carries the whole thread quoted beneath it; only the new text
        // is the message. Without this the pane is fed the entire history, and
        // no command could parse — the previous reply's quote sits right below.
        let body = MailBody.newContent(of: text)
        guard !body.isEmpty else { onOutcome?(.rejected("empty_body")); return }

        // A command is a question about the fleet, not something to type at an
        // agent, so it is answered before any of the binding machinery — it has
        // to work in a thread that has no pane bound to it yet.
        if body.hasPrefix("/") {
            answerCommand(body, message: message)
            return
        }

        // Prose goes to the pane this thread was bound to by `/pane <n>`.
        //
        // Deliberately not gated on the pane being idle. iMessage has never
        // gated bare prose, and a terminal buffers input anyway — an agent
        // mid-turn picks the line up when it finishes. Refusing instead meant a
        // reply written while the agent was working vanished with no reply at
        // all, which is the one outcome mail can't afford.
        if let existing = store.conversation(for: message.threadId), !existing.closed {
            // `sendText` falls back to the pane's persistent session when its
            // tab was never opened and there is no surface to type into — which
            // is the normal case for mail, since being away from the desk is the
            // entire reason for sending one.
            if control.sendText(paneId: existing.paneID, text: body, enter: true) {
                onOutcome?(.delivered)
            } else {
                // Never fail silently: the sender is owed an answer even when
                // the pane it was talking to is gone.
                answer("That pane is gone. `/pane` to see what's left.", message: message)
            }
            return
        }

        // Unbound, so mail behaves exactly as iMessage does: prose steers
        // whichever pane is currently current. `/pane <n>` is the per-thread
        // override on top of that, not a precondition for talking at all.
        guard let reply = onMain({ [weak self] in self?.commandContext?.steerCurrent(body) }) else {
            onOutcome?(.rejected("no_current_pane")); return
        }
        answer(reply, message: message)
    }

    private func answerCommand(_ body: String, message: GmailInboundMessage) {
        guard let result = onMain({ [weak self] in self?.commandContext?.interpret(body) }) else {
            onOutcome?(.rejected("context_unavailable")); return
        }
        switch result {
        case .reply(let text):
            answer(text, message: message)
        case .bind(let paneID, let sessionKey, let worktreePath, let text):
            store.save(.init(gmailThreadID: message.threadId, paneSessionKey: sessionKey, paneID: paneID,
                             projectAlias: "", worktreePath: worktreePath, closed: false,
                             // Remembered so the agent's own output later reaches
                             // the person who bound this thread, not the mailbox.
                             commander: GmailInboundValidator.senderAddress(of: message)))
            answer(text, message: message)
        }
    }

    private func answer(_ body: String, message: GmailInboundMessage) {
        // Back to whoever asked, not to the mailbox being read. Once a second
        // account is allowed to command Seahelm, answering into the Gmail
        // account means the person who sent the command never sees the reply.
        onReply?(body, message.threadId, message.header("subject") ?? "",
                 GmailInboundValidator.senderAddress(of: message))
        onOutcome?(.answered)
    }

    /// `MailPaneRouter` runs on a per-thread serial queue; every context read
    /// walks ShipLog, which belongs to main.
    private func onMain<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread { return work() }
        var result: T?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { result = work(); semaphore.signal() }
        semaphore.wait()
        return result!
    }
}

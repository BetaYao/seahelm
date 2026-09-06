import Foundation

/// Turns one inbound mail into one command line for the executor, and mails
/// whatever comes back.
///
/// Mail owns no verbs and no binding logic of its own any more: the thread is
/// the session (`mail:<thread id>`), so `/go`, `/new` and bare prose mean
/// exactly what they mean on a phone. What is mail's is the shape of the
/// message — quoted history to strip, attachments to file — and the fact that
/// every reply is a new mail in the thread.
final class MailPaneRouter {
    typealias Route = (_ text: String, _ surface: CommandSurface, _ reply: @escaping (CommandReply) -> Void) -> Void

    enum Outcome: Equatable { case answered; case rejected(String) }
    var onOutcome: ((Outcome) -> Void)?
    /// Replies in-thread. `(body, threadID, inboundSubject, replyTo)`.
    var onReply: ((String, String, String, String) -> Void)?
    /// The shared executor, set by the app layer. Runs on the main thread.
    var route: Route?

    private let sessions: CommandSessionStore
    private let attachmentStore: EmailAttachmentStore
    private let attachmentAccount: String?
    private let queue = DispatchQueue(label: "seahelm.gmail-mail-router")
    private var threadQueues: [String: DispatchQueue] = [:]

    init(sessions: CommandSessionStore,
         attachmentStore: EmailAttachmentStore = EmailAttachmentStore(),
         accountEmail: String? = nil) {
        self.sessions = sessions
        self.attachmentStore = attachmentStore
        self.attachmentAccount = accountEmail
    }

    func route(message: GmailInboundMessage, text: String) {
        queue.sync {
            if threadQueues[message.threadId] == nil {
                threadQueues[message.threadId] = DispatchQueue(label: "seahelm.gmail-thread.\(message.threadId)")
            }
        }
        threadQueues[message.threadId]?.async { [weak self] in self?.routeSerial(message: message, text: text) }
    }

    private func routeSerial(message: GmailInboundMessage, text: String) {
        if !message.attachments.isEmpty, let attachmentAccount {
            do {
                _ = try attachmentStore.importAttachments(message.attachments, account: attachmentAccount,
                                                          threadID: message.threadId, messageID: message.id,
                                                          limit: 20 * 1_024 * 1_024)
            } catch {
                onOutcome?(.rejected("attachment_rejected"))
                return
            }
        }
        // A reply carries the whole thread quoted beneath it; only the new text
        // is the message. Without this the pane is fed the entire history, and
        // no command could parse — the previous reply's quote sits right below.
        let body = MailBody.newContent(of: text)
        guard !body.isEmpty else {
            onOutcome?(.rejected("empty_body"))
            return
        }
        guard let route else {
            onOutcome?(.rejected("route_unavailable"))
            return
        }

        // Back to whoever asked, not to the mailbox being read: once a second
        // account may command Seahelm, answering into the Gmail account means
        // the person who sent the command never sees the reply.
        let sender = GmailInboundValidator.senderAddress(of: message)
        let surface = CommandSurface(
            sessionKey: CommandSession.key(surface: "mail", id: message.threadId),
            isDesktop: false,
            commander: sender)
        let subject = message.header("subject") ?? ""
        // The executor walks AgentRegistry, which belongs to main. Replies may
        // land later — `/new` answers twice — and each is its own mail.
        DispatchQueue.main.async { [weak self] in
            route(body, surface) { reply in
                guard !reply.text.isEmpty else { return }
                self?.onReply?(reply.text, message.threadId, subject, sender)
                self?.onOutcome?(.answered)
            }
        }
    }
}

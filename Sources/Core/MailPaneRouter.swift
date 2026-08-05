import Foundation

struct EmailConversation: Codable, Equatable {
    let gmailThreadID: String
    let paneSessionKey: String
    let paneID: String
    let projectAlias: String
    let worktreePath: String
    var closed: Bool
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

protocol MailPaneCreating: AnyObject {
    func createMailPane(worktreePath: String, completion: @escaping (Result<(paneID: String, paneSessionKey: String), Error>) -> Void)
}

/// Serializes one Gmail thread, uses no focus state, and has exactly one input
/// side effect: the existing ControlDataSource submit path.
final class MailPaneRouter {
    enum Outcome: Equatable { case created; case delivered; case rejected(String) }
    var onOutcome: ((Outcome) -> Void)?
    private let control: ControlDataSource
    private weak var creator: MailPaneCreating?
    private let store: EmailConversationStore
    private let attachmentStore: EmailAttachmentStore
    private let attachmentAccount: String?
    private let queue = DispatchQueue(label: "seahelm.gmail-mail-router")
    private var threadQueues: [String: DispatchQueue] = [:]

    init(control: ControlDataSource, creator: MailPaneCreating, store: EmailConversationStore = EmailConversationStore(),
         attachmentStore: EmailAttachmentStore = EmailAttachmentStore(), accountEmail: String? = nil) {
        self.control = control; self.creator = creator; self.store = store; self.attachmentStore = attachmentStore; self.attachmentAccount = accountEmail
    }

    func route(message: GmailInboundMessage, project: GmailMailProjectRule, text: String) {
        queue.sync { if threadQueues[message.threadId] == nil { threadQueues[message.threadId] = DispatchQueue(label: "seahelm.gmail-thread.\(message.threadId)") } }
        threadQueues[message.threadId]?.async { [weak self] in self?.routeSerial(message: message, project: project, text: text) }
    }

    @discardableResult func close(paneID: String) -> EmailConversation? { store.close(paneID: paneID) }

    private func routeSerial(message: GmailInboundMessage, project: GmailMailProjectRule, text: String) {
        if !message.attachments.isEmpty, let attachmentAccount {
            do { _ = try attachmentStore.importAttachments(message.attachments, account: attachmentAccount, threadID: message.threadId, messageID: message.id, limit: 20 * 1_024 * 1_024) }
            catch { onOutcome?(.rejected("attachment_rejected")); return }
        }
        if let existing = store.conversation(for: message.threadId) {
            guard !existing.closed, control.paneStatus(paneId: existing.paneID) == SailorStatus.waiting.rawValue else { onOutcome?(.rejected("pane_not_waiting")); return }
            onOutcome?(control.sendText(paneId: existing.paneID, text: text, enter: true) ? .delivered : .rejected("pane_missing")); return
        }
        guard let creator else { onOutcome?(.rejected("creator_unavailable")); return }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(paneID: String, paneSessionKey: String), Error>?
        DispatchQueue.main.async { creator.createMailPane(worktreePath: project.worktreePath) { value in result = value; semaphore.signal() } }
        semaphore.wait()
        guard case .success(let pane)? = result else { onOutcome?(.rejected("pane_create_failed")); return }
        store.save(.init(gmailThreadID: message.threadId, paneSessionKey: pane.paneSessionKey, paneID: pane.paneID, projectAlias: project.normalizedAlias, worktreePath: project.worktreePath, closed: false))
        guard control.sendText(paneId: pane.paneID, text: text, enter: true) else { onOutcome?(.rejected("pane_missing")); return }
        onOutcome?(.created)
    }
}

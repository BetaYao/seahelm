import Foundation

/// Which message in each chat an agent's next steps belong under.
///
/// A suggestion card carries no words of its own worth sending: its summary and
/// the completion notice already on the phone are both the agent's final prose.
/// So its options are added to that notice as buttons, and this remembers where
/// that notice is — one per chat per pane, the newest replacing the last.
///
/// Entries expire. Past the window the chat has moved on, and buttons appearing
/// under a message the reader has stopped looking at are worse than none: they
/// offer a next step for a turn that has scrolled away.
struct ChatNoticeBook: Equatable {
    /// A message a chat is holding, and when it was sent.
    struct Ref: Equatable {
        let chatId: String
        let messageId: String
        let at: Date

        init(chatId: String, messageId: String, at: Date = Date()) {
            self.chatId = chatId
            self.messageId = messageId
            self.at = at
        }
    }

    /// How long a notice stays the message an agent's next steps belong under.
    static let window: TimeInterval = 180

    private var refs: [String: [Ref]] = [:]

    init() {}

    /// The newest notice about `pane` in this chat, replacing any older one.
    mutating func record(pane: String, chatId: String, messageId: String, at: Date = Date()) {
        guard !pane.isEmpty else { return }
        var list = (refs[pane] ?? []).filter { $0.chatId != chatId }
        list.append(Ref(chatId: chatId, messageId: messageId, at: at))
        refs[pane] = list
    }

    /// Notices about `pane` still recent enough to attach to.
    func recent(pane: String, now: Date = Date()) -> [Ref] {
        guard !pane.isEmpty else { return [] }
        let cutoff = now.addingTimeInterval(-Self.window)
        return (refs[pane] ?? []).filter { $0.at >= cutoff }
    }

    /// Drop what can no longer be attached to, so a long-running fleet does not
    /// accumulate a row per pane it once said something about.
    mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.window)
        refs = refs.compactMapValues { list in
            let live = list.filter { $0.at >= cutoff }
            return live.isEmpty ? nil : live
        }
    }

    var isEmpty: Bool { refs.isEmpty }
}

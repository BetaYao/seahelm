import Foundation

/// Where in Telegram a conversation lives: a chat, and — in a forum
/// supergroup — the topic inside it.
///
/// Everything downstream of the bridge treats a chat id as an opaque string:
/// `CommandSession` keys on `telegram:<id>`, `ChatNoticeBook` remembers which
/// message carried a card there, `ChatProgressReporter` edits a line per id.
/// A forum topic is a second coordinate, and threading it through all of that
/// as a separate field would touch every one of those seams for no gain. So it
/// travels *inside* the string — `-1001234567890#42` — and is split apart again
/// at the one place it means anything, the Bot API call.
///
/// The consequence is the feature: two topics in one group are two addresses,
/// so they are two sessions with their own `/go` binding, their own progress
/// line and their own buttons, and neither can answer for the other.
///
/// `#` is safe as the separator: a chat id is `-?[0-9]+` and a thread id is a
/// positive integer, so neither can contain one.
enum TelegramChatAddress {
    static let separator: Character = "#"

    /// The General topic is not a thread you can send to. Telegram numbers it
    /// 1, does not stamp `message_thread_id` on messages posted there, and
    /// answers `sendMessage` with `message_thread_id: 1` with "message thread
    /// not found" — General is addressed by leaving the thread off entirely.
    static let generalTopicId = 1

    /// The address a message arrived at, and so the address a reply goes back
    /// to.
    ///
    /// A thread is recorded only for a message Telegram marked as a topic
    /// message in a supergroup. Both halves of that matter: `message_thread_id`
    /// is also set on an ordinary reply chain in a plain group, where sending
    /// it back is an error, and since Bot API 10.0 it appears on private-chat
    /// topics, which reject a threaded send outright.
    static func of(_ message: TelegramMessage) -> String {
        encode(chatId: String(message.chat.id), threadId: topicId(of: message))
    }

    /// The topic a message belongs to, or nil when it belongs to none that can
    /// be replied into.
    static func topicId(of message: TelegramMessage) -> Int? {
        guard message.isTopicMessage == true,
              message.chat.type == "supergroup",
              let thread = message.messageThreadId,
              thread != generalTopicId else { return nil }
        return thread
    }

    static func encode(chatId: String, threadId: Int?) -> String {
        guard let threadId, threadId != generalTopicId else { return chatId }
        return "\(chatId)\(separator)\(threadId)"
    }

    /// Split an address for the wire. An id with no thread — every private
    /// chat, every plain group, and General — comes back unchanged with a nil
    /// thread, which is exactly what the API wants.
    ///
    /// Anything unparseable is handed back whole as the chat id: a malformed
    /// address should fail as one bad `sendMessage` Telegram explains, not as a
    /// silent delivery to a chat id we invented by truncating it.
    static func split(_ address: String) -> (chatId: String, threadId: Int?) {
        guard let index = address.lastIndex(of: separator) else { return (address, nil) }
        let thread = Int(address[address.index(after: index)...])
        guard let thread, thread > 0 else { return (address, nil) }
        return (String(address[..<index]), thread)
    }

    /// The chat an address names, with any topic dropped — what a setting that
    /// means "the group" should store.
    static func chatId(of address: String) -> String { split(address).chatId }

    /// One address per chat, so a pane several conversations point at is still
    /// only said once in each room.
    ///
    /// A pane collects bindings: someone says `/go` in the group, again in a
    /// topic, and auto-topics open a thread of its own — three addresses, one
    /// room, and every notice arriving three times. They are all real bindings,
    /// so none of them is wrong to have; what is wrong is treating a chat and a
    /// topic inside it as different audiences.
    ///
    /// The survivor is the most specific place the pane has: its own topic if
    /// it has one (that thread exists for exactly this), then any topic, then
    /// the chat at large. Chats other than this one are untouched — a private
    /// chat bound to the same pane is a different conversation and still hears
    /// it.
    static func oneAddressPerChat(_ addresses: [String], preferring preferred: String?) -> [String] {
        var best: [String: String] = [:]
        for address in addresses {
            let chat = chatId(of: address)
            guard let held = best[chat] else {
                best[chat] = address
                continue
            }
            if rank(address, preferred: preferred) > rank(held, preferred: preferred) {
                best[chat] = address
            }
        }
        return best.values.sorted()
    }

    private static func rank(_ address: String, preferred: String?) -> Int {
        if let preferred, address == preferred { return 3 }
        return split(address).threadId == nil ? 1 : 2
    }
}

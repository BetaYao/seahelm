import Foundation

/// What a chat button stands for.
///
/// Every button on a chat surface resolves to one of these. `command` is the
/// general case — the button is a line the tapper could have typed, and it runs
/// through the same `CommandExecutor` as if they had. The card cases are the
/// exception: a First Mate option is answered by driving the pane's TUI, not by
/// a verb, so it names the card and the option instead.
enum ChatCallbackAction: Equatable {
    /// Run this line through the command language, as if it were typed.
    case command(String)
    /// Pick an option on a First Mate card, by its index in `action.options`.
    case suggestionOption(orderId: String, index: Int)
    /// Clear a First Mate card without answering it.
    case dismissSuggestion(orderId: String)
}

/// Mints the short tokens chat buttons carry.
///
/// Telegram caps `callback_data` at 64 bytes and what a button means does not
/// fit inside it: a card's id is `<worktree path>#<kind>#<pane>`, and an agent's
/// suggested option is a whole sentence. So the button carries a token and the
/// meaning stays here. It also keeps the wire free of anything worth reading —
/// what travels is `k3`, not a path on this machine.
///
/// Deliberately memory-only. A Telegram message lives in the chat's history
/// forever and its buttons with it, so a tap can arrive from last week; tokens
/// die with the run, and a tap that resolves to nothing is answered as stale
/// rather than replayed against a fleet that has moved on.
final class ChatCallbackRegistry {
    static let shared = ChatCallbackRegistry()

    /// Enough for a long session's worth of live cards and listings. Past it the
    /// oldest token is dropped: the buttons above it in the chat have scrolled
    /// out of the part of history anyone still taps.
    static let capacity = 2000

    private let lock = NSLock()
    private var actions: [String: ChatCallbackAction] = [:]
    /// Mint order, so eviction takes the oldest.
    private var order: [String] = []
    private var next = 1

    init() {}

    /// A token for `action`, unique within this run.
    func mint(_ action: ChatCallbackAction) -> String {
        lock.lock()
        defer { lock.unlock() }
        let token = String(next, radix: 36)
        next += 1
        actions[token] = action
        order.append(token)
        if order.count > Self.capacity {
            let evicted = order.removeFirst()
            actions.removeValue(forKey: evicted)
        }
        return token
    }

    /// What the button means, or nil once it has gone stale.
    func action(for token: String) -> ChatCallbackAction? {
        lock.lock()
        defer { lock.unlock() }
        return actions[token]
    }

    /// Retire every button belonging to a card.
    ///
    /// Called when the card is answered or dismissed, and it is the only thing
    /// standing between a resolved card and a second tap: `resolve(id:)` on a
    /// card that has already left the queue is a no-op, but the option text
    /// would still be typed into the pane a second time. Stripping the buttons
    /// off the message races with a tap already in flight; this does not.
    func retire(orderId: String) {
        lock.lock()
        defer { lock.unlock() }
        let stale = actions.filter { Self.orderId(of: $0.value) == orderId }.map(\.key)
        guard !stale.isEmpty else { return }
        for token in stale { actions.removeValue(forKey: token) }
        let dropped = Set(stale)
        order.removeAll { dropped.contains($0) }
    }

    private static func orderId(of action: ChatCallbackAction) -> String? {
        switch action {
        case .command: return nil
        case .suggestionOption(let orderId, _): return orderId
        case .dismissSuggestion(let orderId): return orderId
        }
    }
}

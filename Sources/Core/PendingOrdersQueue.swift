import Foundation

struct PendingOrder: Equatable, Identifiable {
    let id: String
    let action: FirstMateAction
}

/// Remembers which suggestion cards a surface (the island, the First Mate
/// sidebar) has already shown, so it can pop for a genuinely new ask and stay
/// quiet for one already on screen.
///
/// Ids alone cannot answer that. `PendingOrdersQueue.key` is stable per pane, so
/// a second suggestion from the same pane reuses the id: `upsert` swaps the card's
/// contents in place and an id-set comparison sees nothing new — the surface stayed
/// collapsed for every suggestion after the first, until the user happened to
/// resolve one. Fingerprinting what the card actually *shows* is what fixes that.
struct SuggestionSeenSet {
    struct Fingerprint: Equatable {
        let message: String
        let options: [String]

        init(_ order: PendingOrder) {
            message = order.action.message
            options = order.action.options ?? []
        }
    }

    private var seen: [String: Fingerprint] = [:]
    /// A viewport can miss an approval dialog for a frame while it is still
    /// blocking the agent. Do not turn that brief absence into a brand-new
    /// card on the next frame: the island would re-open and Telegram would
    /// send another full question card. Real new cards still win immediately
    /// when their contents differ.
    private var recentlyAbsent: [String: (fingerprint: Fingerprint, at: Date)] = [:]
    static let reappearanceGrace: TimeInterval = 60 * 60

    /// Record `orders` as the full set now on offer and return the ones this
    /// surface has not shown yet. Cards that left the queue are forgotten, so a
    /// re-raised card counts as new again.
    mutating func absorb(_ orders: [PendingOrder], now: Date = Date()) -> [PendingOrder] {
        let incomingIDs = Set(orders.map(\.id))
        for (id, fingerprint) in seen where !incomingIDs.contains(id) {
            recentlyAbsent[id] = (fingerprint, now)
        }
        recentlyAbsent = recentlyAbsent.filter { _, absent in
            now.timeIntervalSince(absent.at) < Self.reappearanceGrace
        }

        let fresh = orders.filter { order in
            if let current = seen[order.id] {
                return Self.isFresh(order, seen: current)
            }
            guard let absent = recentlyAbsent[order.id] else { return true }
            return Self.isFresh(order, seen: absent.fingerprint)
        }
        seen = Dictionary(orders.map { ($0.id, Fingerprint($0)) }, uniquingKeysWith: { _, last in last })
        for id in incomingIDs { recentlyAbsent[id] = nil }
        return fresh
    }

    /// A card is fresh when its id is new, when its options changed, or when its
    /// summary was rewritten into something other than a late prose upgrade.
    /// `PendingOrdersQueue.refreshSuggestMessage` swaps a junk summary (tool
    /// chrome) for the agent's real prose while leaving the options alone — that
    /// is the same ask reading better, not a new one, and must not re-pop.
    private static func isFresh(_ order: PendingOrder, seen: Fingerprint?) -> Bool {
        guard let seen else { return true }
        let now = Fingerprint(order)
        if seen.options != now.options { return true }
        if seen.message == now.message { return false }
        return !FirstMate.isJunkSuggestionSummary(seen.message)
    }
}

/// Red-zone pending-orders queue. At most one entry per (worktreePath, kind) — idempotent.
/// Must be used on the main thread.
final class PendingOrdersQueue {
    private(set) var orders: [PendingOrder] = []

    /// Multiple surfaces observe the queue (sidebar First Mate tab + Helm cockpit).
    /// Token-based so a recreated observer can unregister its old closure.
    private var observers: [Int: () -> Void] = [:]
    private var nextToken = 0

    @discardableResult
    func addObserver(_ block: @escaping () -> Void) -> Int {
        let token = nextToken
        nextToken += 1
        observers[token] = block
        return token
    }

    func removeObserver(_ token: Int?) {
        if let token { observers.removeValue(forKey: token) }
    }

    private func notify() { observers.values.forEach { $0() } }

    /// Pane-scoped for actions that name a terminal (suggestions and questions come
    /// from one specific pane, and two panes of a worktree must be able to hold a
    /// card each). Worktree- and app-scoped actions (integrationReport, broadcastOrder)
    /// carry no terminalID and keep their worktree-wide key.
    static func key(_ a: FirstMateAction) -> String {
        var base = "\(a.worktreePath)#\(a.kind)"
        if !a.terminalID.isEmpty { base += "#\(a.terminalID)" }
        return a.payload.map { "\(base)#\($0)" } ?? base
    }

    func enqueue(_ action: FirstMateAction) {
        let id = Self.key(action)
        guard !orders.contains(where: { $0.id == id }) else { return }
        orders.append(PendingOrder(id: id, action: action))
        notify()
    }

    /// Replace-on-same-id. Used for suggest orders where a newer suggestion supersedes the older.
    func upsert(_ action: FirstMateAction) {
        let id = Self.key(action)
        let order = PendingOrder(id: id, action: action)
        if let idx = orders.firstIndex(where: { $0.id == id }) {
            guard orders[idx] != order else { return }
            orders.remove(at: idx)
        }
        // Preserve arrival order. Replacing a pane's suggestion is a new arrival,
        // so consumers that show newest-first can move it back to the top.
        orders.append(order)
        notify()
    }

    /// Upgrade a suggest card's summary after late assistant prose arrives
    /// (Cursor `afterAgentResponse` often lands after a Shell-invoked
    /// `seahelm-suggest` already queued the options with tool-chrome as message).
    /// Leaves options untouched; never clobbers a non-junk summary already shown.
    func refreshSuggestMessage(terminalID: String, message: String) {
        let summary = FirstMate.suggestionSummaryText(from: message)
        guard !summary.isEmpty else { return }
        var changed = false
        for i in orders.indices {
            let action = orders[i].action
            guard action.kind == .suggestNextOrder,
                  action.terminalID == terminalID,
                  FirstMate.isJunkSuggestionSummary(action.message) else { continue }
            let updated = FirstMateAction(
                kind: action.kind, zone: action.zone,
                worktreePath: action.worktreePath, branch: action.branch,
                project: action.project, terminalID: action.terminalID,
                message: summary, payload: action.payload,
                options: action.options, followups: action.followups)
            orders[i] = PendingOrder(id: orders[i].id, action: updated)
            changed = true
        }
        if changed { notify() }
    }

    /// Every removal goes through here, so a card that leaves the queue takes
    /// its chat buttons with it.
    ///
    /// A card mirrored to a phone leaves a message that keeps its keyboard for
    /// as long as the chat exists. Stripping the buttons off that message is
    /// best effort and races a tap already in flight; retiring the tokens is
    /// not — it is the one thing that makes a tap on an answered card inert
    /// instead of typing the option into the pane a second time.
    @discardableResult
    private func remove(where predicate: (PendingOrder) -> Bool) -> Bool {
        let dropped = orders.filter(predicate)
        guard !dropped.isEmpty else { return false }
        orders.removeAll(where: predicate)
        for order in dropped { ChatCallbackRegistry.shared.retire(orderId: order.id) }
        notify()
        return true
    }

    /// Drop a pane's open suggestion without acting on it. Returns whether
    /// anything went, so a remote caller can tell "declined" from "already gone".
    @discardableResult
    func dismissSuggestion(terminalID: String) -> Bool {
        remove { $0.action.kind == .suggestNextOrder && $0.action.terminalID == terminalID }
    }

    func all() -> [PendingOrder] { orders }

    func resolve(id: String) {
        remove { $0.id == id }
    }

    /// Remove the pending AskUserQuestion card for the given pane — its agent moved
    /// past the question (it was answered in the TUI), so the card is stale.
    /// Pane-scoped: a sibling pane's unanswered question must survive.
    func resolveQuestion(terminalID: String) {
        remove {
            FirstMateAction.isQuestionPayload($0.action.payload)
                && $0.action.terminalID == terminalID
        }
    }

    /// Remove the pending suggest order for the given pane. Pane-scoped: typing in
    /// one pane must not clear a sibling pane's suggestions.
    func resolveSuggest(terminalID: String) {
        remove { $0.action.kind == .suggestNextOrder && $0.action.terminalID == terminalID }
    }

    /// Drop every card belonging to a pane that is gone — closed, or its agent
    /// exited. Until this ran, a suggestion outlived its pane: the card stayed on
    /// screen naming a terminalID that no longer resolves, and tapping one of its
    /// options sent text to a terminal that isn't there.
    ///
    /// Only pane-scoped cards match. `integrationReport` and `broadcastOrder` carry no
    /// terminalID (see `key`) because they belong to the worktree or the whole
    /// app, and must outlive any single pane — the empty-id guard is what keeps
    /// one pane's death from sweeping them away.
    func resolvePane(terminalID: String) {
        guard !terminalID.isEmpty else { return }
        remove { $0.action.terminalID == terminalID }
    }

    /// Drop every card for a worktree that is gone. Used when a whole worktree is
    /// deleted, which takes all of its panes with it — including the
    /// worktree-scoped cards `resolvePane` deliberately spares.
    func resolveWorktree(path: String) {
        guard !path.isEmpty else { return }
        remove { $0.action.worktreePath == path }
    }
}

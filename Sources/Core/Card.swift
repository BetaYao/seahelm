import Foundation

/// Something waiting on the user, as seahelm-core holds it (`cards.list`,
/// core-registry `cards.rs`): an agent's question, a choice on its screen, its
/// suggested next orders, or a card a client or First Mate raised. The app
/// renders cards and answers them through the core; it holds no queue of its
/// own (docs/app-reads-core.md).
struct Card: Equatable, Identifiable {
    enum Kind: String {
        /// AskUserQuestion, answered in the agent's dialog.
        case question
        /// A numbered choice found on screen (a permission prompt).
        case choice
        /// The agent's suggested next orders.
        case suggestion
        /// Legacy: only the removed integration feature raised these, and the
        /// app that would act on their answer is gone. Kept so `CardDeck` can
        /// recognise one still in the core's queue and dismiss it.
        case report
        /// First Mate wants to do something its policy says to ask about.
        case approval
        /// First Mate's recommendation with options.
        case proposal
    }

    let id: String
    let kind: Kind
    let paneSessionKey: String
    /// The app's pane for it, "" when it has none here.
    let terminalID: String
    let worktreePath: String
    let branch: String
    let project: String
    let message: String
    let options: [String]
    /// What to tap: the options, ticked on a multi-select question, then Done.
    let labels: [String]
    let multiSelect: Bool
    let checked: [Int]
    let payload: String?
    let createdAt: Date
    /// AskUserQuestion's tab title for the question ("Customer"), "" without.
    let header: String
    /// The line under each option in the agent's dialog, index for index with
    /// `options` ("" where one has none); empty when there are none.
    let details: [String]

    /// The description to draw under `labels[index]`: the matching option's,
    /// nothing for Done or when the details do not line up.
    func detail(forLabelAt index: Int) -> String {
        guard details.count == options.count, details.indices.contains(index) else { return "" }
        return details[index]
    }

    /// Asks the agent something in its own terminal.
    var isAgentQuestion: Bool { kind == .question || kind == .choice }
    /// First Mate's own ask.
    var isFirstMates: Bool { kind == .approval || kind == .proposal }

    static let doneLabel = "✔ Done"

    init?(json d: [String: Any], terminalID: (String, String) -> String?) {
        guard let id = d["id"] as? String, let kind = Kind(rawValue: d["kind"] as? String ?? "") else { return nil }
        self.id = id
        self.kind = kind
        paneSessionKey = d["pane_session_key"] as? String ?? ""
        self.terminalID = terminalID(paneSessionKey, d["pane_id"] as? String ?? "") ?? ""
        worktreePath = d["worktree_path"] as? String ?? ""
        branch = d["branch"] as? String ?? ""
        project = d["project"] as? String ?? ""
        message = d["message"] as? String ?? ""
        options = d["options"] as? [String] ?? []
        labels = d["labels"] as? [String] ?? options
        multiSelect = d["multi_select"] as? Bool ?? false
        checked = d["checked"] as? [Int] ?? []
        payload = d["payload"] as? String
        createdAt = Date(timeIntervalSince1970: d["created_at"] as? Double ?? 0)
        header = (d["header"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        details = (d["details"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    #if DEBUG
    init(id: String, kind: Kind, terminalID: String = "", worktreePath: String = "", message: String = "",
         options: [String] = [], multiSelect: Bool = false, payload: String? = nil,
         header: String = "", details: [String] = []) {
        self.id = id; self.kind = kind; paneSessionKey = ""; self.terminalID = terminalID
        self.worktreePath = worktreePath; branch = ""; project = ""; self.message = message
        self.options = options; labels = multiSelect ? options.map { "☐ " + $0 } + [Self.doneLabel] : options
        self.multiSelect = multiSelect; checked = []; self.payload = payload; createdAt = Date()
        self.header = header; self.details = details
    }
    #endif
}

/// The core's cards, mirrored for the app's surfaces (island, Telegram, web).
/// Main thread.
final class CardDeck {
    private(set) var cards: [Card] = []
    private var observers: [Int: () -> Void] = [:]
    private var nextToken = 0
    /// Card ids with an `cards.answer` still in flight. A second tap before the
    /// first round-trip finishes would otherwise type the option again — Cursor
    /// Agent queues that as a follow-up and leaves it in the composer after the
    /// turn. Main thread.
    private var answeringIDs: Set<String> = []
    /// Test seam: when set, called instead of the core socket. `done` must run
    /// so the in-flight gate releases (sync or later).
    var answerImpl: ((_ card: Card, _ label: String, _ done: @escaping () -> Void) -> Void)?

    func start() {
        CoreClient.shared.observe { [weak self] event in
            switch event {
            case .cards(let rows):
                self?.replace(rows.compactMap { Card(json: $0, terminalID: CoreClient.terminalID(session:alias:)) })
            default:
                break
            }
        }
    }

    @discardableResult
    func addObserver(_ block: @escaping () -> Void) -> Int {
        nextToken += 1
        observers[nextToken] = block
        return nextToken
    }

    func removeObserver(_ token: Int?) {
        if let token { observers.removeValue(forKey: token) }
    }

    func card(id: String) -> Card? { cards.first { $0.id == id } }

    /// The question a pane is waiting on, if any.
    func question(terminalID: String) -> Card? {
        cards.first { $0.isAgentQuestion && $0.terminalID == terminalID }
    }

    /// Answer a card with one of its labels; the core acts on it (keys into
    /// the agent, an approval run, a raised card back to its owner) and sends
    /// the cards again. Ignores a second answer for the same id while the first
    /// is still in flight.
    func answer(_ card: Card, label: String) {
        guard answeringIDs.insert(card.id).inserted else { return }
        let done = { [weak self] in
            let release = {
                self?.answeringIDs.remove(card.id)
                return
            }
            if Thread.isMainThread { release() } else { DispatchQueue.main.async(execute: release) }
        }
        if let answerImpl {
            answerImpl(card, label, done)
            return
        }
        var params: [String: Any] = ["id": card.id]
        if let i = card.labels.firstIndex(of: label) { params["index"] = i } else { params["option"] = label }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done() }
            if case .failure(let e) = CoreSocketClient.call("cards.answer", params) {
                NSLog("[cards] answer \(card.id) failed: \(e)")
            }
        }
    }

    func dismiss(_ card: Card) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CoreSocketClient.call("cards.dismiss", ["id": card.id])
        }
    }

    /// A worktree is gone: so is every card about it.
    func clear(worktreePath: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CoreSocketClient.call("cards.clear", ["worktree_path": worktreePath])
        }
    }

    /// Report cards already dismissed, so each is asked about once.
    private var retiredReportIDs: Set<String> = []

    /// Take the core's cards as they are now. A leftover integration report
    /// (see `Card.Kind.report`) is dismissed rather than shown: answering it
    /// would do nothing, and the web and Telegram would keep offering it.
    func replace(_ incoming: [Card]) {
        for card in incoming where card.kind == .report && retiredReportIDs.insert(card.id).inserted {
            dismiss(card)
        }
        let next = incoming.filter { $0.kind != .report }
        guard next != cards else { return }
        cards = next
        observers.values.forEach { $0() }
    }
}

/// Which cards a surface (the island, a chat) has already shown, so it pops
/// for a genuinely new ask and stays quiet for one already up. Ids alone
/// cannot say: a pane's next suggestion reuses its card's key, so what the
/// card shows is fingerprinted too.
struct SuggestionSeenSet {
    private struct Fingerprint: Equatable {
        let message: String
        let options: [String]
        init(_ card: Card) { message = card.message; options = card.options }
    }

    private var seen: [String: Fingerprint] = [:]
    /// A screen choice can drop out of the core's view for a frame while it
    /// still blocks the agent; its return is not a new card.
    private var recentlyAbsent: [String: (fingerprint: Fingerprint, at: Date)] = [:]
    static let reappearanceGrace: TimeInterval = 60 * 60

    /// Record `cards` as the full set now on offer; return the ones this
    /// surface has not shown yet.
    mutating func absorb(_ cards: [Card], now: Date = Date()) -> [Card] {
        let incoming = Set(cards.map(\.id))
        for (id, f) in seen where !incoming.contains(id) { recentlyAbsent[id] = (f, now) }
        recentlyAbsent = recentlyAbsent.filter { now.timeIntervalSince($0.value.at) < Self.reappearanceGrace }
        let fresh = cards.filter { card in
            if let current = seen[card.id] { return current != Fingerprint(card) }
            // A question asked again is a new ask, even in the same words.
            guard card.kind != .question, let absent = recentlyAbsent[card.id] else { return true }
            return absent.fingerprint != Fingerprint(card)
        }
        seen = Dictionary(cards.map { ($0.id, Fingerprint($0)) }, uniquingKeysWith: { _, last in last })
        for id in incoming { recentlyAbsent[id] = nil }
        return fresh
    }
}

import SwiftUI
import Combine

/// Single source of truth for the watch UI. Subscribes the MQTT client's decoded
/// events into a `slot → Pane` table and derives the repo/worktree tree, counts,
/// and orders the design's screens consume.
@MainActor
final class Store: ObservableObject {
    @Published var repos: [Repo] = []
    @Published var counts = Counts()
    @Published var orders: [Order] = []
    @Published var conn: ConnState = .disconnected
    @Published var everConnected = false   // first successful connect (gates the connecting screen)
    @Published var online = false          // Mac presence (LWT)
    @Published var dnd = DndState()
    @Published var config = WatchConfig.current

    /// Mac offline OR socket down → read-only, dimmed.
    var offline: Bool { !online || conn != .connected }
    var cap: Capability { config.capability }

    private var panes: [String: Pane] = [:]     // slot → pane (from pane/status)
    private var events: [String: (q: Question?, s: Suggest?)] = [:]   // slot → open decision (from pane/event)
    private var client: MQTTClient

    init(config: WatchConfig? = nil) {
        let cfg = config ?? Store.loadConfig()
        self.config = cfg
        self.client = MQTTClient(config: cfg)
        wire()
    }

    func start() { client.connect() }
    func stop() { client.disconnect() }

    /// Apply a new broker config (from Settings): persist, tear down, reconnect.
    func reconnect(with cfg: WatchConfig) {
        Store.saveConfig(cfg)
        config = cfg
        client.disconnect()
        panes.removeAll(); rebuild(); online = false
        client = MQTTClient(config: cfg)
        wire()
        client.connect()
    }

    // MARK: - Config persistence

    private static let key = "seahelm.watch.config"
    static func loadConfig() -> WatchConfig {
        if let d = UserDefaults.standard.data(forKey: key),
           let c = try? JSONDecoder().decode(WatchConfig.self, from: d) { return c }
        return WatchConfig()
    }
    static func saveConfig(_ c: WatchConfig) {
        if let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: key) }
    }

    private func wire() {
        client.onState = { [weak self] s in self?.conn = s; if s == .connected { self?.everConnected = true } }
        client.onPresence = { [weak self] on in self?.online = on }
        client.onDnd = { [weak self] o in
            self?.dnd = DndState(on: o["on"] as? Bool ?? false,
                                 minutes: o["minutes"] as? Int ?? 25,
                                 blocked: o["blocked"] as? Int ?? 0)
        }
        client.onFocus = { _ in /* counts come from pane rollup; focus is advisory */ }
        client.onPaneStatus = { [weak self] slot, payload in self?.applyStatus(slot, payload) }
        client.onPaneEvent = { [weak self] slot, ev in self?.applyEvent(slot, ev) }
        client.onWorktree = { _, _ in /* rolled up from panes locally */ }
    }

    // MARK: - Ingest

    private func applyStatus(_ slot: String, _ p: [String: Any]?) {
        guard let p else { panes[slot] = nil; rebuild(); return }   // tombstone → drop
        var pane = panes[slot] ?? Pane(
            id: slot, paneUUID: p["pane_id"] as? String ?? "",
            agent: p["agent_type"] as? String ?? "",
            status: .unknown, brief: "",
            project: p["project"] as? String ?? "—",
            worktreePath: p["worktree_path"] as? String ?? "—",
            branch: p["branch"] as? String ?? "")
        pane.paneUUID = p["pane_id"] as? String ?? pane.paneUUID
        pane.agent = p["agent_type"] as? String ?? pane.agent
        pane.status = PaneStatus.from(p["status"] as? String ?? "")
        pane.project = p["project"] as? String ?? pane.project
        pane.worktreePath = p["worktree_path"] as? String ?? pane.worktreePath
        pane.branch = p["branch"] as? String ?? pane.branch
        let title = (p["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let last = (p["last_message"] as? String ?? "")
        pane.brief = title.isEmpty ? last : title
        panes[slot] = pane
        rebuild()
    }

    private func applyEvent(_ slot: String, _ ev: [String: Any]?) {
        guard let ev else { events[slot] = nil; rebuild(); return }   // tombstone → decision resolved
        switch ev["type"] as? String {
        case "question":
            let prompt = ev["prompt"] as? String ?? ev["message"] as? String ?? ""
            events[slot] = (Question(
                questionId: ev["question_id"] as? String ?? "",
                prompt: prompt,
                options: ev["options"] as? [String] ?? [],
                danger: (ev["danger"] as? Bool) ?? ModelBuilder.isDanger(prompt)), nil)
        case "suggest":
            events[slot] = (nil, Suggest(
                suggestId: ev["suggest_id"] as? String ?? "",
                message: ev["message"] as? String ?? "选择下一步",
                options: ev["options"] as? [String] ?? []))
        default: break
        }
        rebuild()
    }

    /// Compose panes + open decisions (order-independent — retained pane/status and
    /// pane/event can arrive in any order on connect).
    private func rebuild() {
        var merged = panes
        for (slot, e) in events where merged[slot] != nil {
            merged[slot]!.question = e.q
            merged[slot]!.suggest = e.s
        }
        repos = ModelBuilder.repos(from: Array(merged.values))
        counts = ModelBuilder.counts(repos)
        orders = ModelBuilder.orders(repos)
    }

    // MARK: - Lookup

    func pane(_ slot: String) -> (pane: Pane, repo: Repo, wt: Worktree)? {
        for r in repos { for w in r.worktrees {
            if let p = w.panes.first(where: { $0.id == slot }) { return (p, r, w) }
        }}
        return nil
    }

    // MARK: - Actions

    func loadHistory(_ slot: String, limit: Int = 10, then: @escaping ([HistoryMsg]) -> Void) {
        client.history(paneSessionKey: slot, limit: limit) { raw in
            let msgs = raw.map { HistoryMsg(
                kind: $0["kind"] as? String ?? "agent",
                text: $0["text"] as? String ?? "",
                seq: $0["seq"] as? Int ?? 0) }
            DispatchQueue.main.async { then(msgs) }
        }
    }

    func resolve(_ pane: Pane, index: Int) {
        guard cap.canPick else { return }
        client.resolve(paneSessionKey: pane.id,
                       questionId: pane.question?.questionId,
                       suggestId: pane.suggest?.suggestId, index: index)
        // optimistic: clear the decision + flip to running
        if var p = panes[pane.id] { p.question = nil; p.suggest = nil; p.status = .running; panes[pane.id] = p; rebuild() }
    }

    func send(_ pane: Pane, text: String) {
        guard cap.canType, !text.isEmpty else { return }
        client.sendText(paneSessionKey: pane.id, text: text)
    }

    func setDnd(on: Bool, minutes: Int? = nil) {
        client.setDnd(on: on, minutes: minutes ?? dnd.minutes)
        dnd.on = on; if let m = minutes { dnd.minutes = m }
    }
}

import Foundation

/// Open questions and suggestions, tracked so the Host Gateway can both push them
/// and answer them.
///
/// MQTT got this for free: decisions went out as *retained* topics, so a client
/// connecting at any time received whatever was still open. A WebSocket has no
/// such memory, so the state has to live here and be replayed on authentication —
/// otherwise a browser that connects one second after a question is raised waits
/// forever for an event it already missed.
///
/// Pure logic, no transport: the server feeds it EventHub events and sends
/// whatever it returns.
final class HostGatewayDecisions {
    struct Decision: Equatable {
        let paneSessionKey: String
        let paneId: String
        let kind: String            // "question" | "suggest"
        let prompt: String
        let options: [String]
        let seq: Int
    }

    private var open: [String: Decision] = [:]
    private let lock = NSLock()

    /// What a single EventHub event does to the set.
    enum Change: Equatable {
        case opened(Decision)
        case cleared(paneSessionKey: String)
        case none
    }

    /// Danger wording is advisory — it only styles the card. Kept deliberately
    /// small; the authority on what a prompt means is the prompt itself.
    private static let dangerRE = try? NSRegularExpression(
        pattern: "(delete|remove|rm -rf|drop|force|reset --hard|overwrite|revoke)",
        options: .caseInsensitive)

    static func isDanger(_ s: String) -> Bool {
        guard let re = dangerRE else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    @discardableResult
    func apply(event: [String: Any]) -> Change {
        let key = event["pane_session_key"] as? String ?? ""
        guard !key.isEmpty else { return .none }
        let paneId = event["pane_id"] as? String ?? ""
        let seq = event["seq"] as? Int ?? 0

        if let q = event["question"] as? [String: Any] {
            let d = Decision(paneSessionKey: key, paneId: paneId, kind: "question",
                             prompt: q["prompt"] as? String ?? "",
                             options: q["options"] as? [String] ?? [], seq: seq)
            lock.lock(); open[key] = d; lock.unlock()
            return .opened(d)
        }
        if let s = event["suggest"] as? [String: Any] {
            // Carried in `prompt`: it is the text the options answer, which is the
            // same role a question's prompt plays. The wire keeps them distinct.
            let d = Decision(paneSessionKey: key, paneId: paneId, kind: "suggest",
                             prompt: s["message"] as? String ?? "",
                             options: s["options"] as? [String] ?? [], seq: seq)
            lock.lock(); open[key] = d; lock.unlock()
            return .opened(d)
        }
        // Only a *question* dies when its pane stops waiting: the prompt it
        // belongs to is gone from the screen, so answering it would key nothing.
        //
        // A suggestion is the opposite. It is raised as the agent *finishes* — the
        // Stop hook is what emits `::seahelm-suggest::` — so the pane is already
        // idle when the options arrive. Clearing on "not waiting" therefore killed
        // every suggestion one status poll after it appeared, which is why the
        // desktop island could hold a card the browser never saw. A suggestion
        // ends when it is picked, replaced, or the pane starts working again.
        if let status = event["status"] as? String {
            lock.lock()
            let existing = open[key]
            let expired: Bool
            switch existing?.kind {
            case "question": expired = status != AgentStatus.waiting.rawValue
            case "suggest":  expired = status == AgentStatus.running.rawValue
            default:         expired = false
            }
            if expired { open.removeValue(forKey: key) }
            lock.unlock()
            return expired ? .cleared(paneSessionKey: key) : .none
        }
        return .none
    }

    func options(forPaneSessionKey key: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return open[key]?.options ?? []
    }

    func clear(paneSessionKey key: String) {
        lock.lock(); open.removeValue(forKey: key); lock.unlock()
    }

    /// Everything still open, for replay to a client that just authenticated.
    func pending() -> [Decision] {
        lock.lock(); defer { lock.unlock() }
        return open.values.sorted { $0.seq < $1.seq }
    }

    /// Wire shape. Matches what the web client already renders for MQTT
    /// `pane/<key>/event`, so the browser needed no new card format.
    static func notifyParams(for d: Decision) -> [String: Any] {
        var p: [String: Any] = [
            "type": d.kind,
            "pane_id": d.paneId,
            "pane_session_key": d.paneSessionKey,
            "options": d.options,
            "seq": d.seq,
        ]
        if d.kind == "question" {
            p["prompt"] = d.prompt
            p["danger"] = isDanger(d.prompt)
        } else if !d.prompt.isEmpty {
            // `message` rather than `prompt`: a suggestion is not asking, it is
            // reporting — and the client renders the two the same way anyway.
            p["message"] = d.prompt
        }
        return p
    }

    static func clearedParams(paneSessionKey key: String) -> [String: Any] {
        ["pane_session_key": key, "cleared": true]
    }
}

import Foundation

enum MessageKind: String, Equatable {
    case user, assistant, tool, status, decision, notice
    /// What the agent narrates while it works — Claude's visible thinking, a Codex
    /// reasoning summary. Shown apart from what it says.
    case thinking
    /// A line seahelm-core wrote into the timeline itself (First Mate's sweep
    /// reports): no turn behind it, drawn as one line of note.
    case note
    /// First Mate's daily brief, composed by seahelm-core (no turn): a title
    /// line and one line per section, drawn as a block.
    case brief
    /// A card entering or leaving the shared queue. Repeated rows for a card
    /// share `cardId`; readers merge them at the first row's position.
    case card
}

enum CardTimelineState: String, Equatable {
    case pending, answered, dismissed, expired, gone

    static func read(_ value: String?) -> CardTimelineState? {
        guard let value else { return nil }
        return CardTimelineState(rawValue: value) ?? .gone
    }
}

/// The durable part of a card in First Mate's timeline. The live `CardDeck`
/// card remains the authority for pending options and answers.
struct CardTimelineEntry: Equatable, Identifiable {
    let id: String // card_id
    let sequence: UInt64 // first row; keeps the card in place when later rows arrive
    let createdAt: Date
    var updatedAt: Date
    var cardKind: String
    var sourcePane: String?
    var sourceLabel: String
    var text: String
    var options: [String]
    var state: CardTimelineState
    var option: String?
    var via: String?

    func effectiveState(liveCard: Card?) -> CardTimelineState {
        state == .pending && liveCard == nil ? .gone : state
    }

    static func merged(from messages: [MessageEvent]) -> [CardTimelineEntry] {
        var entries: [String: CardTimelineEntry] = [:]
        var order: [String] = []
        for event in messages.sorted(by: { $0.seq < $1.seq }) where event.kind == .card {
            guard let id = event.cardId, let state = event.cardState else { continue }
            if var entry = entries[id] {
                entry.updatedAt = event.ts
                if let kind = event.cardKind { entry.cardKind = kind }
                if let pane = event.cardSourcePane { entry.sourcePane = pane }
                if let label = event.cardSourceLabel { entry.sourceLabel = label }
                if let text = event.text { entry.text = text }
                if let options = event.cardOptions { entry.options = options }
                entry.state = state
                if let option = event.cardOption { entry.option = option }
                if let via = event.cardVia { entry.via = via }
                entries[id] = entry
            } else {
                order.append(id)
                entries[id] = CardTimelineEntry(
                    id: id, sequence: event.seq, createdAt: event.ts, updatedAt: event.ts,
                    cardKind: event.cardKind ?? "", sourcePane: event.cardSourcePane,
                    sourceLabel: event.cardSourceLabel ?? "", text: event.text ?? "",
                    options: event.cardOptions ?? [], state: state,
                    option: event.cardOption, via: event.cardVia
                )
            }
        }
        return order.compactMap { entries[$0] }
    }
}

struct MessageEvent: Equatable {
    var seq: UInt64
    var paneId: String
    var paneSessionKey: String
    var kind: MessageKind
    var ts: Date
    var text: String? = nil
    var tool: String? = nil
    var detail: String? = nil
    var isError: Bool? = nil
    var status: String? = nil
    var oldStatus: String? = nil
    var count: Int = 1
    var cardId: String? = nil
    var cardKind: String? = nil
    var cardSourcePane: String? = nil
    var cardSourceLabel: String? = nil
    var cardOptions: [String]? = nil
    var cardState: CardTimelineState? = nil
    var cardOption: String? = nil
    var cardVia: String? = nil

    var dict: [String: Any] {
        var d: [String: Any] = [
            "seq": seq,
            "pane_id": paneId,
            "pane_session_key": paneSessionKey,
            "kind": kind.rawValue,
            "ts": ts.timeIntervalSince1970,
        ]
        if let text { d["text"] = text }
        if let tool { d["tool"] = tool }
        if let detail { d["detail"] = detail }
        if let isError { d["is_error"] = isError }
        if let status { d["status"] = status }
        if let oldStatus { d["old_status"] = oldStatus }
        if count > 1 { d["count"] = count }
        if let cardId { d["card_id"] = cardId }
        if let cardKind { d["card_kind"] = cardKind }
        if cardSourcePane != nil || cardSourceLabel != nil {
            var source: [String: Any] = [:]
            if let cardSourcePane { source["pane"] = cardSourcePane }
            if let cardSourceLabel { source["label"] = cardSourceLabel }
            d["source"] = source
        }
        if let cardOptions { d["options"] = cardOptions }
        if let cardState { d["state"] = cardState.rawValue }
        if let cardOption { d["option"] = cardOption }
        if let cardVia { d["via"] = cardVia }
        return d
    }

    /// The pane this event belongs to across restarts. The seahelmd session name
    /// survives a relaunch; the station id is only a fallback for panes without one.
    var ringKey: String { paneSessionKey.isEmpty ? paneId : paneSessionKey }
}

extension MessageEvent {
    /// Inverse of `dict`, for events read back from disk.
    init?(dict d: [String: Any]) {
        guard let seq = (d["seq"] as? NSNumber)?.uint64Value,
              let paneId = d["pane_id"] as? String,
              let kind = (d["kind"] as? String).flatMap(MessageKind.init(rawValue:)),
              let ts = d["ts"] as? Double else { return nil }
        self.init(seq: seq, paneId: paneId,
                  paneSessionKey: d["pane_session_key"] as? String ?? "",
                  kind: kind, ts: Date(timeIntervalSince1970: ts))
        text = d["text"] as? String
        tool = d["tool"] as? String
        detail = d["detail"] as? String
        isError = d["is_error"] as? Bool
        status = d["status"] as? String
        oldStatus = d["old_status"] as? String
        count = d["count"] as? Int ?? 1
        cardId = d["card_id"] as? String
        cardKind = d["card_kind"] as? String
        if let source = d["source"] as? [String: Any] {
            cardSourcePane = source["pane"] as? String ?? (source["pane"] as? NSNumber)?.stringValue
            cardSourceLabel = source["label"] as? String
        }
        cardOptions = d["options"] as? [String]
        cardState = CardTimelineState.read(d["state"] as? String)
        cardOption = d["option"] as? String
        cardVia = d["via"] as? String
    }
}

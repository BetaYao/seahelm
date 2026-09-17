import Foundation

enum PaneMessageProjector {
    struct CoalesceState: Equatable {
        var lastTool: String? = nil
        var lastDetail: String? = nil
        var lastIsError: Bool? = nil
        var lastCount: Int = 0
        /// The decision already on the timeline. A TUI approval dialog is
        /// re-ingested as `.question` on every rescan while it stays on screen,
        /// so only the agent running again, a new prompt or a tool run opens a new one.
        var lastDecision: [String]? = nil
        static let empty = CoalesceState()
    }

    /// Pure projection. Leaves `seq` at 0 — `MessageStreamHub` stamps sequences on append.
    static func project(
        outcome: IngestOutcome,
        config: MessageConfig,
        coalesce: CoalesceState,
        now: Date = Date()
    ) -> (events: [MessageEvent], coalesce: CoalesceState) {
        var out: [MessageEvent] = []
        var coal = coalesce
        let paneId = outcome.info.id
        let key = outcome.info.station?.paneSessionKey ?? ""

        func base(_ kind: MessageKind) -> MessageEvent {
            MessageEvent(seq: 0, paneId: paneId, paneSessionKey: key,
                         kind: kind, ts: now)
        }

        if outcome.statusChanged {
            if isTurnEdge(from: outcome.oldStatus, to: outcome.newStatus) {
                var e = base(.status)
                e.status = outcome.newStatus.rawValue
                e.oldStatus = outcome.oldStatus.rawValue
                out.append(e)
            }
            // While an approval dialog is on screen the scan reports Idle and the
            // dialog reports Waiting on every poll, so a status edge alone is not
            // the decision being answered. Only running again is.
            let decision = coal.lastDecision
            coal = .empty
            if outcome.newStatus != .running { coal.lastDecision = decision }
        }

        func appendDecision(_ text: String, signature: [String]) {
            guard coal.lastDecision != signature else { return }
            var e = base(.decision)
            e.text = text
            out.append(e)
            coal.lastDecision = signature
        }

        switch outcome.event.kind {
        case .userPrompt(let text):
            coal.lastDecision = nil
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                var e = base(.user)
                e.text = trimmed
                out.append(e)
            }
        case .toolUse(let act):
            coal.lastDecision = nil
            let name = config.toolAliases[act.tool] ?? act.tool
            if config.coalesceTools,
               coal.lastTool == name,
               coal.lastDetail == act.detail,
               coal.lastIsError == act.isError {
                coal.lastCount += 1
            } else {
                var e = base(.tool)
                e.tool = name
                e.detail = act.detail
                e.isError = act.isError
                out.append(e)
                coal.lastTool = name
                coal.lastDetail = act.detail
                coal.lastIsError = act.isError
                coal.lastCount = 1
            }
        case .question(let prompt, let options, _):
            appendDecision(prompt, signature: ["question", prompt] + options)
        case .suggest(let options):
            appendDecision(options.joined(separator: " · "), signature: ["suggest"] + options)
        case .notification(_, let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                var e = base(.notice)
                e.text = t
                out.append(e)
            }
        case .agentStopped:
            break
        case .screenObserved(_, let message, _, _, _, _, _, _):
            if config.screenFallback {
                let t = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    var e = base(.notice)
                    e.text = t
                    out.append(e)
                }
            }
        default:
            break
        }

        if outcome.isCompletionSignal {
            let prose = outcome.info.lastAssistantMessage
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prose.isEmpty {
                var e = base(.assistant)
                e.text = prose
                out.append(e)
            }
        }

        return (out, coal)
    }

    /// Which status changes earn a row: a turn starting or ending, and an error.
    /// Idle ↔ Waiting is detection settling — during one approval dialog it flips
    /// every poll — and leaving `.unknown` is a pane being registered.
    static func isTurnEdge(from old: AgentStatus, to new: AgentStatus) -> Bool {
        guard old != .unknown else { return false }
        return old == .running || new == .running || new == .error
    }
}

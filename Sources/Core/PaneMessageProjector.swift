import Foundation

enum PaneMessageProjector {
    struct CoalesceState: Equatable {
        var lastTool: String? = nil
        var lastDetail: String? = nil
        var lastIsError: Bool? = nil
        var lastCount: Int = 0
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
            var e = base(.status)
            e.status = outcome.newStatus.rawValue
            e.oldStatus = outcome.oldStatus.rawValue
            out.append(e)
            coal = .empty
        }

        switch outcome.event.kind {
        case .userPrompt(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                var e = base(.user)
                e.text = trimmed
                out.append(e)
            }
        case .toolUse(let act):
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
            var e = base(.decision)
            e.text = prompt
            _ = options
            out.append(e)
        case .suggest(let options):
            var e = base(.decision)
            e.text = options.joined(separator: " · ")
            out.append(e)
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
}

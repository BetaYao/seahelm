import AppKit

/// How an integration checkout reads in the fleet list.
///
/// A checkout has no agent. `idle` / `running` there describes whatever shell
/// happens to be open in it — which is why that row's status dot has always
/// said nothing worth reading, and why the two groupings that sort *by* status
/// leave the checkout out of the list entirely. What a person wants from that
/// row is whether the last round landed.
///
/// So the dot means something else on this one row. That is a smaller lie than
/// the one it replaces: a green dot on a checkout whose round dropped two
/// worktrees.
enum IntegrationRowStatus: Equatable {
    /// No round has run here yet.
    case notBuilt
    /// Everything on offer went in and was checked out.
    case clean
    /// Work was dropped, what landed carries markers, or the result was built
    /// and held back.
    case attention
    /// The round did not run at all.
    case failed

    init(_ state: IntegrationPanelState?) {
        guard let state else {
            self = .notBuilt
            return
        }
        if state.failure != nil {
            self = .failed
        } else if state.needsAttention {
            self = .attention
        } else {
            self = .clean
        }
    }

    /// One column wide, like every other dot in the list — `⑃` is the merge
    /// glyph the integration banner already uses, so a clean checkout is
    /// recognisable as one rather than as an idle agent.
    var glyph: String {
        switch self {
        case .notBuilt:  return "◌"
        case .clean:     return "⑃"
        case .attention: return "!"
        case .failed:    return "✕"
        }
    }

    /// Shared with `AgentStatus.color`, so "wants you" and "broke" read the
    /// same here as they do on every other row.
    var color: NSColor {
        switch self {
        case .notBuilt:  return SemanticColors.subtle
        case .clean:     return SemanticColors.idle
        case .attention: return SemanticColors.attention
        case .failed:    return SemanticColors.danger
        }
    }
}

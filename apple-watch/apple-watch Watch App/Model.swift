import Foundation

/// PaneStatus — mirrors the Mac's `SailorStatus` rawValues (capitalized on the
/// wire) collapsed to the six the design cares about.
enum PaneStatus: String {
    case running, waiting, done, failed, idle, unknown

    /// Normalize a wire status string (SailorStatus rawValue is capitalized:
    /// Running/Waiting/Error/Exited/Idle/Unknown; mocks use lowercase).
    static func from(_ raw: String) -> PaneStatus {
        switch raw.lowercased() {
        case "running":        return .running
        case "waiting":        return .waiting
        case "error", "failed": return .failed
        case "exited", "done":  return .done
        case "idle":           return .idle
        default:               return .unknown
        }
    }

    /// Attention priority for single-focus selection (lower = more urgent, §5).
    var priority: Int {
        switch self {
        case .waiting: return 0
        case .failed:  return 1
        case .running: return 2
        case .done:    return 3
        case .idle:    return 4
        case .unknown: return 5
        }
    }
}

/// One line in a pane's conversation history (`history/request` reply, or a live
/// final/user message). `kind`: you | agent | ask | run | msg | status.
struct HistoryMsg: Identifiable, Equatable {
    let id = UUID()
    var kind: String
    var text: String
    var seq: Int = 0
    var stamp: String = ""
}

/// An open decision on a pane (from `pane/{slot}/event`).
struct Question: Equatable {
    var questionId: String
    var prompt: String
    var options: [String]
    var danger: Bool = false
}
struct Suggest: Equatable {
    var suggestId: String
    var message: String
    var options: [String]
}

/// A pane (agent) — the leaf of repo → worktree → pane.
struct Pane: Identifiable, Equatable {
    let id: String              // stable slot key (pane_session_key)
    var paneUUID: String        // per-instance pane_id (debug / addressing fallback)
    var agent: String           // agent_type
    var status: PaneStatus
    var brief: String           // title || last_message
    var project: String
    var worktreePath: String
    var branch: String
    var question: Question? = nil
    var suggest: Suggest? = nil
    var history: [HistoryMsg] = []
}

struct Worktree: Identifiable, Equatable {
    let id: String              // worktree_path
    var branch: String
    var project: String
    var last: String            // rolled last message
    var ago: String = ""
    var panes: [Pane]
}

struct Repo: Identifiable, Equatable {
    let id: String              // project
    var name: String
    var worktrees: [Worktree]
}

struct Counts: Equatable {
    var repos = 0, worktrees = 0, panes = 0
    var running = 0, waiting = 0, failed = 0
}

/// A pending decision surfaced in the Orders (待处理) list.
struct Order: Identifiable, Equatable {
    var paneId: String          // slot key
    var agent: String
    var path: String            // repo/branch
    var prompt: String
    var isQuestion: Bool
    var danger: Bool
    var id: String { paneId }
}

struct DndState: Equatable {
    var on = false
    var minutes = 25
    var blocked = 0
}

// MARK: - Derivation

enum ModelBuilder {
    /// Group a flat set of panes into repos → worktrees → panes.
    static func repos(from panes: [Pane]) -> [Repo] {
        var byProject: [String: [String: [Pane]]] = [:]        // project → worktreePath → panes
        var projectOrder: [String] = []
        var wtOrder: [String: [String]] = [:]
        for p in panes.sorted(by: { $0.id < $1.id }) {
            if byProject[p.project] == nil { byProject[p.project] = [:]; projectOrder.append(p.project) }
            if byProject[p.project]![p.worktreePath] == nil {
                byProject[p.project]![p.worktreePath] = []
                wtOrder[p.project, default: []].append(p.worktreePath)
            }
            byProject[p.project]![p.worktreePath]!.append(p)
        }
        return projectOrder.map { proj in
            let wts = (wtOrder[proj] ?? []).map { path -> Worktree in
                let ps = byProject[proj]![path]!
                let branch = ps.first?.branch ?? (path as NSString).lastPathComponent
                let focus = ps.min { $0.status.priority < $1.status.priority }
                return Worktree(id: path, branch: branch, project: proj,
                                last: focus?.brief ?? "", panes: ps)
            }
            return Repo(id: proj, name: proj, worktrees: wts)
        }
    }

    static func counts(_ repos: [Repo]) -> Counts {
        var c = Counts()
        c.repos = repos.count
        for r in repos { for w in r.worktrees { c.worktrees += 1
            for p in w.panes { c.panes += 1
                switch p.status {
                case .running: c.running += 1
                case .waiting: c.waiting += 1
                case .failed:  c.failed += 1
                default: break
                }
            }
        }}
        return c
    }

    static func orders(_ repos: [Repo]) -> [Order] {
        var out: [Order] = []
        for r in repos { for w in r.worktrees { for p in w.panes {
            if let q = p.question {
                out.append(Order(paneId: p.id, agent: p.agent, path: "\(r.name)/\(w.branch)",
                                 prompt: q.prompt, isQuestion: true, danger: q.danger))
            } else if let s = p.suggest {
                out.append(Order(paneId: p.id, agent: p.agent, path: "\(r.name)/\(w.branch)",
                                 prompt: "建议下一步 · " + s.options.joined(separator: " / "),
                                 isQuestion: false, danger: false))
            }
        }}}
        return out
    }

    static let dangerRE = try! NSRegularExpression(
        pattern: "覆盖|删除|prod|生产|部署|deploy|drop|force", options: [.caseInsensitive])
    static func isDanger(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return dangerRE.firstMatch(in: s, range: r) != nil
    }
}

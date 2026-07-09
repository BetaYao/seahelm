import Foundation

/// Declarative, portable split-layout template (herdr's layout.export/apply
/// schema). A committable "project layout" — a BSP tree whose leaves carry an
/// optional command/cwd/label — decoupled from live station ids and PTYs.
///
///   pane:  {"type":"pane",  "label"?, "command"?, "agent"?, "cwd"?}
///   split: {"type":"split", "direction":"right"|"down", "ratio":Double, "first":<node>, "second":<node>}
indirect enum LayoutNode: Equatable {
    case pane(label: String?, command: String?, agent: String?, cwd: String?)
    case split(direction: String, ratio: Double, first: LayoutNode, second: LayoutNode)

    // MARK: JSON

    var dict: [String: Any] {
        switch self {
        case let .pane(label, command, agent, cwd):
            var d: [String: Any] = ["type": "pane"]
            if let label { d["label"] = label }
            if let command { d["command"] = command }
            if let agent { d["agent"] = agent }
            if let cwd { d["cwd"] = cwd }
            return d
        case let .split(direction, ratio, first, second):
            return ["type": "split", "direction": direction, "ratio": ratio,
                    "first": first.dict, "second": second.dict]
        }
    }

    init?(dict: [String: Any]) {
        switch dict["type"] as? String {
        case "pane":
            self = .pane(label: dict["label"] as? String,
                         command: dict["command"] as? String,
                         agent: dict["agent"] as? String,
                         cwd: dict["cwd"] as? String)
        case "split":
            guard let direction = (dict["direction"] as? String)?.lowercased(),
                  ["right", "left", "down", "up"].contains(direction),
                  let first = (dict["first"] as? [String: Any]).flatMap(LayoutNode.init(dict:)),
                  let second = (dict["second"] as? [String: Any]).flatMap(LayoutNode.init(dict:)) else {
                return nil
            }
            let ratio = (dict["ratio"] as? Double) ?? 0.5
            self = .split(direction: direction, ratio: ratio, first: first, second: second)
        default:
            return nil
        }
    }

    /// Number of leaf panes — used to bound how many terminals an apply spawns.
    var paneCount: Int {
        switch self {
        case .pane: return 1
        case let .split(_, _, first, second): return first.paneCount + second.paneCount
        }
    }
}

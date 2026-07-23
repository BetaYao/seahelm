import Foundation

/// A leaf action reachable through the leader (`Space`) which-key tree. These are the
/// concrete commands the UI layer performs when a leader path terminates on a command
/// node. Kept separate from `KeyboardAction` (the bare-key NORMAL-mode dispatch) so the
/// two dispatch surfaces don't entangle.
enum LeaderCommand: Equatable {
    case splitHorizontal
    case splitVertical
    case closePane
    case resetRatio
    case newWorktree
    case deleteWorktree
    case quickSwitcher
    case dashboard
    case toggleSidebar
    case resize(FocusDirection)
    case maximizePane
    case showChanges
    case browseFiles
    case commandPalette
    case keyboardHelp
}

/// A node in the leader which-key tree: either a submenu (descend on its key) or a
/// terminal command (fire on its key).
indirect enum LeaderNode: Equatable {
    case submenu(key: String, label: String, children: [LeaderNode])
    case command(key: String, label: String, command: LeaderCommand)

    var key: String {
        switch self {
        case .submenu(let k, _, _): return k
        case .command(let k, _, _): return k
        }
    }

    var label: String {
        switch self {
        case .submenu(_, let l, _): return l
        case .command(_, let l, _): return l
        }
    }

    var isSubmenu: Bool {
        if case .submenu = self { return true }
        return false
    }
}

/// One rendered row of the which-key bar.
struct LeaderHint: Equatable {
    let key: String
    let label: String
    let isSubmenu: Bool
}

/// The leader (`Space`) command tree and its resolution logic. Pure — the state machine
/// (open/descend/back) lives in `KeyboardModeController`; the which-key rendering + 400ms
/// reveal delay live in the UI layer. See docs/keyboard-redesign.md §5.
enum LeaderMenu {

    /// Root of the tree. Mirrors docs/keyboard-redesign.md §5.
    static let root: [LeaderNode] = [
        .submenu(key: "s", label: "split ▸", children: [
            .command(key: "s", label: "Horizontal split", command: .splitHorizontal),
            .command(key: "v", label: "Vertical split", command: .splitVertical),
            .command(key: "x", label: "Close pane", command: .closePane),
            .command(key: "=", label: "Reset ratio", command: .resetRatio),
        ]),
        .command(key: "n", label: "new project", command: .newWorktree),
        .command(key: "d", label: "delete project", command: .deleteWorktree),
        .submenu(key: "g", label: "go ▸", children: [
            .command(key: "w", label: "Project switcher", command: .quickSwitcher),
            .command(key: "0", label: "dashboard", command: .dashboard),
            .command(key: "b", label: "Toggle sidebar", command: .toggleSidebar),
        ]),
        .submenu(key: "w", label: "window/pane ▸", children: [
            .command(key: "H", label: "Resize ←", command: .resize(.left)),
            .command(key: "J", label: "Resize ↓", command: .resize(.down)),
            .command(key: "K", label: "Resize ↑", command: .resize(.up)),
            .command(key: "L", label: "Resize →", command: .resize(.right)),
            .command(key: "m", label: "Maximize pane", command: .maximizePane),
        ]),
        .command(key: "c", label: "changes", command: .showChanges),
        .command(key: "f", label: "files", command: .browseFiles),
        .command(key: "/", label: "command palette", command: .commandPalette),
        .command(key: "?", label: "keyboard help", command: .keyboardHelp),
    ]

    /// The child nodes visible at a given descent path. Returns `root` for `[]`, the
    /// submenu's children when the path walks into submenus, or `[]` when the path is
    /// invalid or lands on a command (commands have no children).
    static func entries(at path: [String]) -> [LeaderNode] {
        var level = root
        for key in path {
            guard case .submenu(_, _, let children)? = level.first(where: { $0.key == key }) else {
                return []
            }
            level = children
        }
        return level
    }

    /// The which-key rows to render at a given path.
    static func hints(at path: [String]) -> [LeaderHint] {
        entries(at: path).map { LeaderHint(key: $0.key, label: $0.label, isSubmenu: $0.isSubmenu) }
    }

    enum Resolution: Equatable {
        case descend           // key opens a submenu → append to path
        case fire(LeaderCommand)   // key is a terminal command → run it and close leader
        case unknown           // no matching entry at this level
    }

    /// Resolve pressing `key` at the current `path`.
    static func resolve(path: [String], key: String) -> Resolution {
        guard let node = entries(at: path).first(where: { $0.key == key }) else {
            return .unknown
        }
        switch node {
        case .submenu:                return .descend
        case .command(_, _, let cmd): return .fire(cmd)
        }
    }
}

import Foundation

/// Manages the lifecycle of SplitTree instances, keyed by worktree path.
class StationManager {
    private var trees: [String: SplitTree] = [:]

    /// Get or create a SplitTree for the given worktree info.
    /// Creates a single-leaf tree and registers the station in StationRegistry.
    func tree(for info: WorktreeInfo, backend: String) -> SplitTree {
        if let existing = trees[info.path] {
            return existing
        }
        let station = Station()
        let sessionName = backend != "local" ? SessionManager.persistentSessionName(for: info.path) : ""
        if backend != "local" {
            station.sessionName = sessionName
            station.backend = backend
        }
        StationRegistry.shared.register(station)
        let leafId = UUID().uuidString
        let splitTree = SplitTree(
            worktreePath: info.path,
            rootLeafId: leafId,
            stationId: station.id,
            sessionName: sessionName
        )
        trees[info.path] = splitTree
        return splitTree
    }

    /// Look up an existing tree by worktree path.
    func tree(forPath path: String) -> SplitTree? {
        trees[path]
    }

    /// Every live tree, for bulk persistence (e.g. capturing pane titles at quit).
    var allTrees: [SplitTree] { Array(trees.values) }

    /// Register a pre-built tree (e.g. restored from config) for the given path.
    /// Does nothing if a tree already exists for that path.
    func registerTree(_ tree: SplitTree, forPath path: String) {
        guard trees[path] == nil else { return }
        trees[path] = tree
    }

    /// Remove and destroy a tree for the given path.
    @discardableResult
    func removeTree(forPath path: String) -> SplitTree? {
        guard let tree = trees.removeValue(forKey: path) else { return nil }
        for leaf in tree.allLeaves {
            if let station = StationRegistry.shared.station(forId: leaf.stationId) {
                station.destroy()
            }
            StationRegistry.shared.unregister(leaf.stationId)
        }
        return tree
    }

    /// Remove all trees, destroying each station.
    func removeAll() {
        for (_, tree) in trees {
            for leaf in tree.allLeaves {
                if let station = StationRegistry.shared.station(forId: leaf.stationId) {
                    station.destroy()
                }
                StationRegistry.shared.unregister(leaf.stationId)
            }
        }
        trees.removeAll()
    }

    /// All current tree entries.
    var all: [String: SplitTree] {
        trees
    }

    /// Number of managed trees.
    var count: Int {
        trees.count
    }

    /// Re-key an existing tree from one worktree path to another.
    /// Used when a worktree is created and the terminal should follow the new path.
    /// Returns the tree if found, nil if no tree exists at fromPath.
    @discardableResult
    func transferTree(fromPath: String, toPath: String) -> SplitTree? {
        guard let tree = trees.removeValue(forKey: fromPath) else { return nil }
        // Re-home the tree so persistence (saveSplitLayout keys on worktreePath)
        // and station.create's cwd point at the destination, not the old path.
        tree.worktreePath = toPath
        trees[toPath] = tree
        return tree
    }

    // MARK: - Primary station accessor (for ShipLog / backward compat)

    /// Returns the primary (first) station for the given worktree path, if any.
    func primaryStation(forPath path: String) -> Station? {
        guard let tree = trees[path],
              let firstLeaf = tree.allLeaves.first else { return nil }
        return StationRegistry.shared.station(forId: firstLeaf.stationId)
    }
}

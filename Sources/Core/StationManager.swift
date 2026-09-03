import Foundation

/// Manages the lifecycle of SplitTree instances, keyed by worktree path.
class StationManager {
    private var trees: [String: SplitTree] = [:]
    /// Stations this manager stood up itself, in this run — `tree(for:)` and
    /// `replacementTree`. Deliberately not `registerTree`: a layout restored from
    /// config may have its panes attached to zmx sessions with work still in them,
    /// and an empty-looking viewport is no proof otherwise before the attach has
    /// painted. Only a pane on this list is a candidate for being discarded.
    private var autoCreatedStationIds: Set<String> = []

    /// Get or create a SplitTree for the given worktree info.
    /// Creates a single-leaf tree and registers the station in StationRegistry.
    func tree(for info: WorktreeInfo, backend: String) -> SplitTree {
        if let existing = trees[info.path] {
            return existing
        }
        let station = Station()
        let paneSessionKey = backend != "local" ? SessionManager.persistentSessionName(for: info.path) : ""
        if backend != "local" {
            station.paneSessionKey = paneSessionKey
            station.backend = backend
        }
        StationRegistry.shared.register(station)
        autoCreatedStationIds.insert(station.id)
        let leafId = UUID().uuidString
        let splitTree = SplitTree(
            worktreePath: info.path,
            rootLeafId: leafId,
            stationId: station.id,
            paneSessionKey: paneSessionKey
        )
        trees[info.path] = splitTree
        return splitTree
    }

    /// Look up an existing tree by worktree path.
    func tree(forPath path: String) -> SplitTree? {
        trees[path]
    }

    /// Every zmx session name a live tree currently claims.
    var claimedSessionNames: Set<String> {
        Set(trees.values.flatMap { $0.allLeaves.map(\.paneSessionKey) }.filter { !$0.isEmpty })
    }

    /// Stand up a fresh tree for a worktree whose panes have all left.
    ///
    /// It must not simply take `persistentSessionName(for:)` the way `tree(for:)`
    /// does: the pane that moved away kept that exact name — zmx has no rename —
    /// so the replacement would attach to the live session the departed agent is
    /// still running in, and both panes would drive the same terminal. Claims the
    /// first free `<base>`, `<base>-2`, `<base>-3` … instead.
    func replacementTree(for info: WorktreeInfo, backend: String) -> SplitTree {
        if let existing = trees[info.path] { return existing }

        var paneSessionKey = ""
        if backend != "local" {
            let base = SessionManager.persistentSessionName(for: info.path)
            let taken = claimedSessionNames
            paneSessionKey = base
            var index = 2
            while taken.contains(paneSessionKey) {
                paneSessionKey = "\(base)-\(index)"
                index += 1
            }
        }

        let station = Station()
        if backend != "local" {
            station.paneSessionKey = paneSessionKey
            station.backend = backend
        }
        StationRegistry.shared.register(station)
        autoCreatedStationIds.insert(station.id)
        let tree = SplitTree(worktreePath: info.path, rootLeafId: UUID().uuidString,
                             stationId: station.id, paneSessionKey: paneSessionKey)
        trees[info.path] = tree
        return tree
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
            autoCreatedStationIds.remove(leaf.stationId)
        }
        return tree
    }

    /// Whether `stationId` names a pane this manager created rather than restored.
    func wasAutoCreated(stationId: String) -> Bool {
        autoCreatedStationIds.contains(stationId)
    }

    /// The only leaf of `path`'s tree, when the worktree has exactly one pane.
    func soleLeaf(atPath path: String) -> SplitNode.LeafInfo? {
        guard let tree = trees[path], tree.allLeaves.count == 1 else { return nil }
        return tree.allLeaves.first
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
        autoCreatedStationIds.removeAll()
    }

    /// All current tree entries.
    var all: [String: SplitTree] {
        trees
    }

    /// Number of managed trees.
    var count: Int {
        trees.count
    }

    /// The tree containing `stationId`, with the id of its leaf.
    ///
    /// A pane move addresses one pane, not a worktree: the emitting agent names
    /// itself with SEAHELM_PANE_ID, which resolves to a Station, and the tree that
    /// holds it may be any of them.
    func locate(stationId: String) -> (tree: SplitTree, leafId: String)? {
        for (_, tree) in trees {
            if let leaf = tree.allLeaves.first(where: { $0.stationId == stationId }) {
                return (tree, leaf.id)
            }
        }
        return nil
    }

    /// Lift one leaf out of its tree and install it as the whole tree for
    /// `toPath`, keeping the Station and its zmx session alive.
    ///
    /// Returns nil when the station is unknown. When the leaf is the last one in
    /// its tree, the source tree is *unkeyed* (not destroyed — its stations move
    /// with it) and the source worktree is left with no tree at all; the caller
    /// decides what the emptied worktree shows.
    @discardableResult
    func moveLeaf(stationId: String, toPath: String) -> (tree: SplitTree, sourcePath: String, sourceEmptied: Bool)? {
        guard let (sourceTree, leafId) = locate(stationId: stationId) else { return nil }
        let sourcePath = sourceTree.worktreePath
        guard sourcePath != toPath else { return nil }

        let leaf: SplitNode.LeafInfo
        var sourceEmptied = false
        if let removed = sourceTree.removeLeaf(id: leafId) {
            leaf = removed
        } else {
            // Only leaf: the whole tree comes across, so drop the source key
            // without destroying anything.
            guard let only = sourceTree.allLeaves.first else { return nil }
            leaf = only
            trees.removeValue(forKey: sourcePath)
            sourceEmptied = true
        }

        // A worktree that already has panes keeps them — the moved pane joins as a
        // split. Replacing its tree would orphan every Station in it.
        let destination: SplitTree
        if let existing = trees[toPath] {
            existing.adopt(leaf: leaf)
            destination = existing
        } else {
            destination = SplitTree.adopting(leaf: leaf, worktreePath: toPath)
            trees[toPath] = destination
        }
        return (destination, sourcePath, sourceEmptied)
    }

    // MARK: - Primary station accessor (for AgentRegistry / backward compat)

    /// Returns the primary (first) station for the given worktree path, if any.
    func primaryStation(forPath path: String) -> Station? {
        guard let tree = trees[path],
              let firstLeaf = tree.allLeaves.first else { return nil }
        return StationRegistry.shared.station(forId: firstLeaf.stationId)
    }
}

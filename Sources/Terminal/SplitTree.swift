import Foundation

/// Manages a split-pane tree for a single worktree.
/// Each leaf corresponds to one Station + zmx session.
class SplitTree {
    private(set) var root: SplitNode
    var focusedId: String
    /// Owning worktree path. Mutable so a pane transfer (agent creates a new
    /// worktree from its cwd) can re-home the tree; persistence keys on this, so
    /// it must track the destination or the transferred layout saves under the
    /// wrong path and is lost on restart.
    var worktreePath: String
    private let baseSessionName: String

    var leafCount: Int { root.leafCount }
    var allLeaves: [SplitNode.LeafInfo] { root.allLeaves }
    var allStationIds: [String] { root.allLeaves.map(\.stationId) }

    init(worktreePath: String, rootLeafId: String, stationId: String, paneSessionKey: String) {
        self.worktreePath = worktreePath
        self.baseSessionName = paneSessionKey
        self.root = .leaf(id: rootLeafId, stationId: stationId, paneSessionKey: paneSessionKey)
        self.focusedId = rootLeafId
    }

    func nextSessionName() -> String {
        let index = root.nextPaneIndex(baseName: baseSessionName)
        return "\(baseSessionName)-\(index)"
    }

    /// Split the focused leaf. Returns the new leaf id and the id of the split
    /// node created above it (so callers can set its ratio via `updateRatio`).
    @discardableResult
    func splitFocusedLeaf(axis: SplitAxis, newLeafId: String, newStationId: String, newSessionName: String)
        -> (leafId: String, splitId: String) {
        let newLeaf = SplitNode.leaf(id: newLeafId, stationId: newStationId, paneSessionKey: newSessionName)
        let splitId = UUID().uuidString
        guard root.findLeaf(id: focusedId) != nil else { return (newLeafId, splitId) }
        let focusedNode = extractSubnode(id: focusedId)
        let replacement = SplitNode.split(id: splitId, axis: axis, ratio: 0.5, first: focusedNode, second: newLeaf)
        root = root.replacing(leafId: focusedId, with: replacement)
        focusedId = newLeafId
        return (newLeafId, splitId)
    }

    func closeFocusedLeaf() -> SplitNode.LeafInfo? {
        removeLeaf(id: focusedId)
    }

    /// Remove any leaf by id, promoting its sibling. Returns the removed leaf, or
    /// nil when it is not in this tree or is the tree's only leaf — a tree always
    /// keeps a root leaf, so a caller lifting out the last pane drops the whole
    /// tree instead.
    @discardableResult
    func removeLeaf(id: String) -> SplitNode.LeafInfo? {
        guard leafCount > 1 else { return nil }
        guard let leafInfo = root.findLeaf(id: id) else { return nil }
        guard let newRoot = root.removing(leafId: id) else { return nil }
        root = newRoot
        if focusedId == id {
            focusedId = root.allLeaves.first?.id ?? focusedId
        }
        return leafInfo
    }

    /// Insert an existing leaf beside the focused one, keeping its Station and
    /// zmx session. The mirror of `removeLeaf`: together they move a live pane
    /// between trees without recreating it, which is the whole point — the agent
    /// running in that pane must survive the move.
    @discardableResult
    func adopt(leaf: SplitNode.LeafInfo, axis: SplitAxis = .horizontal) -> String {
        let incoming = SplitNode.leaf(id: leaf.id, stationId: leaf.stationId, paneSessionKey: leaf.paneSessionKey)
        // `focusedId` can be stale — removing the focused leaf reassigns it, and a
        // tree can be adopted into after its focus moved. Attach to any leaf rather
        // than to focus alone: replacing `root` outright would orphan every Station
        // already in this tree, which is the one thing a move must never do.
        let anchorId = root.findLeaf(id: focusedId)?.id ?? root.allLeaves.first?.id
        guard let anchorId else {
            root = incoming
            focusedId = leaf.id
            return leaf.id
        }
        let focusedNode = extractSubnode(id: anchorId)
        let replacement = SplitNode.split(id: UUID().uuidString, axis: axis, ratio: 0.5,
                                          first: focusedNode, second: incoming)
        root = root.replacing(leafId: anchorId, with: replacement)
        focusedId = leaf.id
        return leaf.id
    }

    /// Build a tree for `worktreePath` whose only leaf is one lifted out of
    /// another tree, keeping its live Station and zmx session.
    ///
    /// The adopted leaf keeps the session name it was created with — zmx has no
    /// rename, so the running pane stays addressable only by its original name —
    /// while `baseSessionName` is derived from the destination, so panes split off
    /// later are named after the worktree they actually live in.
    static func adopting(leaf: SplitNode.LeafInfo, worktreePath: String) -> SplitTree {
        let node = SplitNode.leaf(id: leaf.id, stationId: leaf.stationId, paneSessionKey: leaf.paneSessionKey)
        let tree = SplitTree(worktreePath: worktreePath,
                             root: node,
                             baseSessionName: SessionManager.persistentSessionName(for: worktreePath))
        tree.focusedId = leaf.id
        return tree
    }

    func updateRatio(splitId: String, newRatio: CGFloat) {
        let clamped = min(max(newRatio, 0.1), 0.9)
        root = root.updatingRatio(splitId: splitId, newRatio: clamped)
    }

    func nearestAncestorSplit(axis: SplitAxis) -> String? {
        root.nearestAncestorSplit(forLeaf: focusedId, axis: axis)
    }

    func toCodable() -> CodableSplitNode {
        CodableSplitNode.from(root)
    }

    // MARK: - Restoration

    /// Restore a SplitTree from a saved codable layout. Returns nil if restoration fails.
    static func restore(from codable: CodableSplitNode, worktreePath: String, backend: String) -> SplitTree? {
        let baseName = SessionManager.persistentSessionName(for: worktreePath)
        let (node, firstLeafId) = restoreNode(from: codable, backend: backend)
        guard let node = node, let firstLeafId = firstLeafId else { return nil }
        let tree = SplitTree(worktreePath: worktreePath, root: node, baseSessionName: baseName)
        tree.focusedId = firstLeafId
        return tree
    }

    /// Private init for restoration (accepts pre-built root).
    private init(worktreePath: String, root: SplitNode, baseSessionName: String) {
        self.worktreePath = worktreePath
        self.root = root
        self.baseSessionName = baseSessionName
        self.focusedId = root.allLeaves.first?.id ?? ""
    }

    private static func restoreNode(from codable: CodableSplitNode, backend: String) -> (SplitNode?, String?) {
        switch codable {
        case .leaf(let paneSessionKey, let title):
            let station = Station()
            station.paneSessionKey = paneSessionKey
            station.backend = backend
            station.persistedTitle = title
            // Bridge the header with the persisted title only until this restored
            // pane's live title arrives — never on a later session in the pane.
            station.titleBridgeActive = (title?.isEmpty == false)
            StationRegistry.shared.register(station)
            let leafId = UUID().uuidString
            return (.leaf(id: leafId, stationId: station.id, paneSessionKey: paneSessionKey), leafId)

        case .split(let axisStr, let ratio, let first, let second):
            guard let axis = SplitAxis(rawValue: axisStr) else { return (nil, nil) }
            let (firstNode, firstLeaf) = restoreNode(from: first, backend: backend)
            let (secondNode, _) = restoreNode(from: second, backend: backend)
            guard let firstNode = firstNode, let secondNode = secondNode else { return (nil, nil) }
            return (.split(id: UUID().uuidString, axis: axis, ratio: CGFloat(ratio), first: firstNode, second: secondNode), firstLeaf)
        }
    }

    private func extractSubnode(id: String) -> SplitNode {
        if case .leaf(let leafId, let stationId, let paneSessionKey) = root, leafId == id {
            return .leaf(id: leafId, stationId: stationId, paneSessionKey: paneSessionKey)
        }
        guard let info = root.findLeaf(id: id) else { return root }
        return .leaf(id: info.id, stationId: info.stationId, paneSessionKey: info.paneSessionKey)
    }
}

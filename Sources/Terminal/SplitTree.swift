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

    init(worktreePath: String, rootLeafId: String, stationId: String, sessionName: String) {
        self.worktreePath = worktreePath
        self.baseSessionName = sessionName
        self.root = .leaf(id: rootLeafId, stationId: stationId, sessionName: sessionName)
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
        let newLeaf = SplitNode.leaf(id: newLeafId, stationId: newStationId, sessionName: newSessionName)
        let splitId = UUID().uuidString
        guard root.findLeaf(id: focusedId) != nil else { return (newLeafId, splitId) }
        let focusedNode = extractSubnode(id: focusedId)
        let replacement = SplitNode.split(id: splitId, axis: axis, ratio: 0.5, first: focusedNode, second: newLeaf)
        root = root.replacing(leafId: focusedId, with: replacement)
        focusedId = newLeafId
        return (newLeafId, splitId)
    }

    func closeFocusedLeaf() -> SplitNode.LeafInfo? {
        guard leafCount > 1 else { return nil }
        guard let leafInfo = root.findLeaf(id: focusedId) else { return nil }
        guard let newRoot = root.removing(leafId: focusedId) else { return nil }
        root = newRoot
        focusedId = root.allLeaves.first?.id ?? focusedId
        return leafInfo
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
        case .leaf(let sessionName, let title):
            let station = Station()
            station.sessionName = sessionName
            station.backend = backend
            station.persistedTitle = title
            // Bridge the header with the persisted title only until this restored
            // pane's live title arrives — never on a later session in the pane.
            station.titleBridgeActive = (title?.isEmpty == false)
            StationRegistry.shared.register(station)
            let leafId = UUID().uuidString
            return (.leaf(id: leafId, stationId: station.id, sessionName: sessionName), leafId)

        case .split(let axisStr, let ratio, let first, let second):
            guard let axis = SplitAxis(rawValue: axisStr) else { return (nil, nil) }
            let (firstNode, firstLeaf) = restoreNode(from: first, backend: backend)
            let (secondNode, _) = restoreNode(from: second, backend: backend)
            guard let firstNode = firstNode, let secondNode = secondNode else { return (nil, nil) }
            return (.split(id: UUID().uuidString, axis: axis, ratio: CGFloat(ratio), first: firstNode, second: secondNode), firstLeaf)
        }
    }

    private func extractSubnode(id: String) -> SplitNode {
        if case .leaf(let leafId, let stationId, let sessionName) = root, leafId == id {
            return .leaf(id: leafId, stationId: stationId, sessionName: sessionName)
        }
        guard let info = root.findLeaf(id: id) else { return root }
        return .leaf(id: info.id, stationId: info.stationId, sessionName: info.sessionName)
    }
}

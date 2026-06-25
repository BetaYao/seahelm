import Foundation

/// Manages a split-pane tree for a single worktree.
/// Each leaf corresponds to one TerminalSurface + zmx session.
class SplitTree {
    private(set) var root: SplitNode
    var focusedId: String
    let worktreePath: String
    private let baseSessionName: String

    var leafCount: Int { root.leafCount }
    var allLeaves: [SplitNode.LeafInfo] { root.allLeaves }
    var allSurfaceIds: [String] { root.allLeaves.map(\.surfaceId) }

    init(worktreePath: String, rootLeafId: String, surfaceId: String, sessionName: String) {
        self.worktreePath = worktreePath
        self.baseSessionName = sessionName
        self.root = .leaf(id: rootLeafId, surfaceId: surfaceId, sessionName: sessionName)
        self.focusedId = rootLeafId
    }

    func nextSessionName() -> String {
        let index = root.nextPaneIndex(baseName: baseSessionName)
        return "\(baseSessionName)-\(index)"
    }

    @discardableResult
    func splitFocusedLeaf(axis: SplitAxis, newLeafId: String, newSurfaceId: String, newSessionName: String) -> String {
        let newLeaf = SplitNode.leaf(id: newLeafId, surfaceId: newSurfaceId, sessionName: newSessionName)
        let splitId = UUID().uuidString
        guard root.findLeaf(id: focusedId) != nil else { return newLeafId }
        let focusedNode = extractSubnode(id: focusedId)
        let replacement = SplitNode.split(id: splitId, axis: axis, ratio: 0.5, first: focusedNode, second: newLeaf)
        root = root.replacing(leafId: focusedId, with: replacement)
        focusedId = newLeafId
        return newLeafId
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
        case .leaf(let sessionName):
            let surface = TerminalSurface()
            surface.sessionName = sessionName
            surface.backend = backend
            SurfaceRegistry.shared.register(surface)
            let leafId = UUID().uuidString
            return (.leaf(id: leafId, surfaceId: surface.id, sessionName: sessionName), leafId)

        case .split(let axisStr, let ratio, let first, let second):
            guard let axis = SplitAxis(rawValue: axisStr) else { return (nil, nil) }
            let (firstNode, firstLeaf) = restoreNode(from: first, backend: backend)
            let (secondNode, _) = restoreNode(from: second, backend: backend)
            guard let firstNode = firstNode, let secondNode = secondNode else { return (nil, nil) }
            return (.split(id: UUID().uuidString, axis: axis, ratio: CGFloat(ratio), first: firstNode, second: secondNode), firstLeaf)
        }
    }

    private func extractSubnode(id: String) -> SplitNode {
        if case .leaf(let leafId, let surfaceId, let sessionName) = root, leafId == id {
            return .leaf(id: leafId, surfaceId: surfaceId, sessionName: sessionName)
        }
        guard let info = root.findLeaf(id: id) else { return root }
        return .leaf(id: info.id, surfaceId: info.surfaceId, sessionName: info.sessionName)
    }
}

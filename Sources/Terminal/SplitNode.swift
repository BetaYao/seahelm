import Foundation

enum SplitAxis: String, Codable {
    case horizontal  // left | right
    case vertical    // top / bottom
}

/// Runtime split tree node. Leaves hold live TerminalSurface references.
indirect enum SplitNode {
    case leaf(id: String, surfaceId: String, sessionName: String)
    case split(id: String, axis: SplitAxis, ratio: CGFloat, first: SplitNode, second: SplitNode)

    var id: String {
        switch self {
        case .leaf(let id, _, _): return id
        case .split(let id, _, _, _, _): return id
        }
    }

    var leafCount: Int {
        switch self {
        case .leaf: return 1
        case .split(_, _, _, let first, let second):
            return first.leafCount + second.leafCount
        }
    }

    struct LeafInfo {
        let id: String
        let surfaceId: String
        let sessionName: String
    }

    var allLeaves: [LeafInfo] {
        switch self {
        case .leaf(let id, let surfaceId, let sessionName):
            return [LeafInfo(id: id, surfaceId: surfaceId, sessionName: sessionName)]
        case .split(_, _, _, let first, let second):
            return first.allLeaves + second.allLeaves
        }
    }

    func findLeaf(id: String) -> LeafInfo? {
        allLeaves.first { $0.id == id }
    }

    /// Derive next pane index from existing session names.
    func nextPaneIndex(baseName: String) -> Int {
        let leaves = allLeaves
        var maxIndex = 0
        for leaf in leaves {
            let name = leaf.sessionName
            if name == baseName {
                continue
            }
            if name.hasPrefix(baseName + "-"),
               let suffix = Int(name.dropFirst(baseName.count + 1)) {
                maxIndex = max(maxIndex, suffix)
            }
        }
        return maxIndex + 1
    }

    /// Replace a leaf node (by id) with a new subtree. Returns modified tree.
    func replacing(leafId: String, with replacement: SplitNode) -> SplitNode {
        switch self {
        case .leaf(let id, _, _):
            return id == leafId ? replacement : self
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(
                id: id, axis: axis, ratio: ratio,
                first: first.replacing(leafId: leafId, with: replacement),
                second: second.replacing(leafId: leafId, with: replacement)
            )
        }
    }

    /// Remove a leaf by id, promoting its sibling.
    /// Returns nil if the target leaf was not found in this subtree.
    /// When a direct child leaf matches, its sibling is promoted (returned).
    /// When a deeper leaf matches, the modified subtree is returned.
    func removing(leafId: String) -> SplitNode? {
        switch self {
        case .leaf(let id, _, _):
            // Leaf doesn't contain the target — return nil to signal "not found here"
            // The parent split handles the case where a direct child leaf matches (lines below)
            return id == leafId ? nil : nil
        case .split(_, _, _, let first, let second):
            // Direct child is the target leaf — promote its sibling
            if first.id == leafId { return second }
            if second.id == leafId { return first }
            // Try removing from first subtree
            if let newFirst = first.removing(leafId: leafId) {
                return .split(id: self.id, axis: axis, ratio: ratio, first: newFirst, second: second)
            }
            // Try removing from second subtree
            if let newSecond = second.removing(leafId: leafId) {
                return .split(id: self.id, axis: axis, ratio: ratio, first: first, second: newSecond)
            }
            // Target not found in either subtree
            return nil
        }
    }

    private var axis: SplitAxis {
        if case .split(_, let axis, _, _, _) = self { return axis }
        fatalError("Not a split node")
    }

    private var ratio: CGFloat {
        if case .split(_, _, let ratio, _, _) = self { return ratio }
        fatalError("Not a split node")
    }

    /// Update ratio on a specific split node by id.
    func updatingRatio(splitId: String, newRatio: CGFloat) -> SplitNode {
        switch self {
        case .leaf: return self
        case .split(let id, let axis, let ratio, let first, let second):
            let r = id == splitId ? newRatio : ratio
            return .split(
                id: id, axis: axis, ratio: r,
                first: first.updatingRatio(splitId: splitId, newRatio: newRatio),
                second: second.updatingRatio(splitId: splitId, newRatio: newRatio)
            )
        }
    }

    /// Find the nearest ancestor split node with the given axis, for a leaf.
    func nearestAncestorSplit(forLeaf leafId: String, axis targetAxis: SplitAxis) -> String? {
        switch self {
        case .leaf: return nil
        case .split(let id, let axis, _, let first, let second):
            let inFirst = first.findLeaf(id: leafId) != nil
            let inSecond = second.findLeaf(id: leafId) != nil
            guard inFirst || inSecond else { return nil }
            let deeper = inFirst
                ? first.nearestAncestorSplit(forLeaf: leafId, axis: targetAxis)
                : second.nearestAncestorSplit(forLeaf: leafId, axis: targetAxis)
            if let deeper = deeper { return deeper }
            return axis == targetAxis ? id : nil
        }
    }
}

// MARK: - Codable representation for config persistence

/// Serializable split layout (no live surface references).
indirect enum CodableSplitNode: Codable {
    case leaf(sessionName: String)
    case split(axis: String, ratio: Double, first: CodableSplitNode, second: CodableSplitNode)

    private enum CodingKeys: String, CodingKey {
        case type, sessionName, axis, ratio, first, second
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if type == "leaf" {
            let name = try container.decode(String.self, forKey: .sessionName)
            self = .leaf(sessionName: name)
        } else {
            let axis = try container.decode(String.self, forKey: .axis)
            let ratio = try container.decode(Double.self, forKey: .ratio)
            let first = try container.decode(CodableSplitNode.self, forKey: .first)
            let second = try container.decode(CodableSplitNode.self, forKey: .second)
            self = .split(axis: axis, ratio: ratio, first: first, second: second)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let sessionName):
            try container.encode("leaf", forKey: .type)
            try container.encode(sessionName, forKey: .sessionName)
        case .split(let axis, let ratio, let first, let second):
            try container.encode("split", forKey: .type)
            try container.encode(axis, forKey: .axis)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }

    /// Convert runtime SplitNode to serializable form.
    static func from(_ node: SplitNode) -> CodableSplitNode {
        switch node {
        case .leaf(_, _, let sessionName):
            return .leaf(sessionName: sessionName)
        case .split(_, let axis, let ratio, let first, let second):
            return .split(axis: axis.rawValue, ratio: Double(ratio), first: from(first), second: from(second))
        }
    }
}

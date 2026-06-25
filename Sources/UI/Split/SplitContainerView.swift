import AppKit

protocol SplitContainerDelegate: AnyObject {
    func splitContainer(_ view: SplitContainerView, didChangeFocus leafId: String)
    func splitContainer(_ view: SplitContainerView, didRequestSplit axis: SplitAxis)
    func splitContainer(_ view: SplitContainerView, didRequestClosePane leafId: String)
    func splitContainerDidChangeLayout(_ view: SplitContainerView)
}

// MARK: - Dim overlay

/// Transparent overlay that dims unfocused panes. Passes all mouse events through
/// so clicks reach the terminal view underneath.
private class DimOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - SplitContainerView

class SplitContainerView: NSView, DividerDelegate {
    var tree: SplitTree? { didSet { layoutTree() } }
    var surfaceViews: [String: NSView] = [:]
    weak var delegate: SplitContainerDelegate?

    private var dividers: [String: DividerView] = [:]
    private var leafFrames: [String: CGRect] = [:]
    private var dimOverlays: [String: DimOverlayView] = [:]

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = true
        setAccessibilityIdentifier("splitPane.container")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutTree()
    }

    func layoutTree() {
        guard let tree = tree else { return }
        leafFrames = Self.computeFrames(node: tree.root, in: bounds)
        for leaf in tree.allLeaves {
            guard let frame = leafFrames[leaf.id],
                  let view = surfaceViews[leaf.surfaceId] else { continue }
            // Deactivate any Auto Layout constraints and switch to frame-based positioning.
            // TerminalSurface.create() sets up Auto Layout, but SplitContainerView uses frames.
            if !view.translatesAutoresizingMaskIntoConstraints {
                NSLayoutConstraint.deactivate(view.constraints)
                // Also remove constraints from superview that reference this view
                if let sv = view.superview {
                    let related = sv.constraints.filter {
                        $0.firstItem as? NSView === view || $0.secondItem as? NSView === view
                    }
                    NSLayoutConstraint.deactivate(related)
                }
                view.translatesAutoresizingMaskIntoConstraints = true
            }
            if view.superview != self {
                view.removeFromSuperview()
                addSubview(view)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.frame = frame
            CATransaction.commit()
            view.setAccessibilityIdentifier("splitPane.leaf.\(leaf.id)")

            // Keep tree.focusedId in sync when user clicks a pane directly
            if let ghosttyView = view as? GhosttyNSView {
                let leafId = leaf.id
                ghosttyView.onFocusAcquired = { [weak self] in
                    guard let self else { return }
                    self.tree?.focusedId = leafId
                    self.delegate?.splitContainer(self, didChangeFocus: leafId)
                    self.updateDimOverlays()
                }
            }

            // Notify Ghostty of the new size
            if let surface = SurfaceRegistry.shared.surface(forId: leaf.surfaceId) {
                surface.syncContentScale()
                surface.syncSize()
            }
        }
        layoutDividers(node: tree.root, in: bounds)
        let activeSplitIds = collectSplitIds(tree.root)
        for (id, divider) in dividers where !activeSplitIds.contains(id) {
            divider.removeFromSuperview()
            dividers.removeValue(forKey: id)
        }
        updateDimOverlays()
    }

    // MARK: - Dim overlays

    /// Update semi-transparent overlays that dim unfocused panes.
    /// Overlays are sibling views above terminals but below dividers, and pass mouse events through.
    func updateDimOverlays() {
        guard let tree = tree else {
            dimOverlays.values.forEach { $0.removeFromSuperview() }
            dimOverlays.removeAll()
            return
        }

        // Single pane: no dimming needed
        guard tree.leafCount > 1 else {
            dimOverlays.values.forEach { $0.removeFromSuperview() }
            dimOverlays.removeAll()
            return
        }

        let focusedId = tree.focusedId
        let activeLeafIds = Set(tree.allLeaves.map(\.id))

        // Remove overlays for leaves that no longer exist
        for id in dimOverlays.keys where !activeLeafIds.contains(id) {
            dimOverlays[id]?.removeFromSuperview()
            dimOverlays.removeValue(forKey: id)
        }

        for leaf in tree.allLeaves {
            if leaf.id == focusedId {
                dimOverlays[leaf.id]?.removeFromSuperview()
                dimOverlays.removeValue(forKey: leaf.id)
            } else {
                let frame = leafFrames[leaf.id] ?? .zero
                if let overlay = dimOverlays[leaf.id] {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    overlay.frame = frame
                    CATransaction.commit()
                } else {
                    let overlay = DimOverlayView(frame: frame)
                    overlay.wantsLayer = true
                    overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
                    // Insert above terminal views but below dividers
                    if let firstDivider = dividers.values.first {
                        addSubview(overlay, positioned: .below, relativeTo: firstDivider)
                    } else {
                        addSubview(overlay)
                    }
                    dimOverlays[leaf.id] = overlay
                }
            }
        }
    }

    // MARK: - Frame computation

    static func computeFrames(node: SplitNode, in rect: CGRect) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        computeFramesRecursive(node: node, in: rect, result: &result)
        return result
    }

    private static func computeFramesRecursive(node: SplitNode, in rect: CGRect, result: inout [String: CGRect]) {
        switch node {
        case .leaf(let id, _, _):
            result[id] = rect
        case .split(_, let axis, let ratio, let first, let second):
            let dividerSize = DividerView.thickness
            switch axis {
            case .horizontal:
                let firstWidth = floor((rect.width - dividerSize) * ratio)
                let secondX = rect.origin.x + firstWidth + dividerSize
                let secondWidth = rect.width - firstWidth - dividerSize
                let firstRect = CGRect(x: rect.origin.x, y: rect.origin.y, width: firstWidth, height: rect.height)
                let secondRect = CGRect(x: secondX, y: rect.origin.y, width: secondWidth, height: rect.height)
                computeFramesRecursive(node: first, in: firstRect, result: &result)
                computeFramesRecursive(node: second, in: secondRect, result: &result)
            case .vertical:
                let firstHeight = floor((rect.height - dividerSize) * ratio)
                let secondY = rect.origin.y + firstHeight + dividerSize
                let secondHeight = rect.height - firstHeight - dividerSize
                let firstRect = CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: firstHeight)
                let secondRect = CGRect(x: rect.origin.x, y: secondY, width: rect.width, height: secondHeight)
                computeFramesRecursive(node: first, in: firstRect, result: &result)
                computeFramesRecursive(node: second, in: secondRect, result: &result)
            }
        }
    }

    private func layoutDividers(node: SplitNode, in rect: CGRect) {
        guard case .split(let id, let axis, let ratio, let first, let second) = node else { return }
        let dividerSize = DividerView.thickness

        let divider: DividerView
        if let existing = dividers[id] {
            divider = existing
        } else {
            divider = DividerView(splitNodeId: id, axis: axis)
            divider.delegate = self
            divider.setAccessibilityIdentifier("splitPane.divider.\(id)")
            addSubview(divider)
            dividers[id] = divider
        }

        switch axis {
        case .horizontal:
            let firstWidth = floor((rect.width - dividerSize) * ratio)
            divider.frame = CGRect(x: rect.origin.x + firstWidth, y: rect.origin.y, width: dividerSize, height: rect.height)
            divider.parentSplitSize = rect.width
            divider.currentRatio = ratio
            let firstRect = CGRect(x: rect.origin.x, y: rect.origin.y, width: firstWidth, height: rect.height)
            let secondRect = CGRect(x: rect.origin.x + firstWidth + dividerSize, y: rect.origin.y, width: rect.width - firstWidth - dividerSize, height: rect.height)
            layoutDividers(node: first, in: firstRect)
            layoutDividers(node: second, in: secondRect)
        case .vertical:
            let firstHeight = floor((rect.height - dividerSize) * ratio)
            divider.frame = CGRect(x: rect.origin.x, y: rect.origin.y + firstHeight, width: rect.width, height: dividerSize)
            divider.parentSplitSize = rect.height
            divider.currentRatio = ratio
            let firstRect = CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: firstHeight)
            let secondRect = CGRect(x: rect.origin.x, y: rect.origin.y + firstHeight + dividerSize, width: rect.width, height: rect.height - firstHeight - dividerSize)
            layoutDividers(node: first, in: firstRect)
            layoutDividers(node: second, in: secondRect)
        }
    }

    private func collectSplitIds(_ node: SplitNode) -> Set<String> {
        switch node {
        case .leaf: return []
        case .split(let id, _, _, let first, let second):
            return Set([id]).union(collectSplitIds(first)).union(collectSplitIds(second))
        }
    }

    // MARK: - Mouse → focus restore

    /// Clicking anywhere on the split container (background, divider gap, etc.)
    /// should restore keyboard focus to the currently-focused terminal leaf.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        restoreFocusToActiveLeaf()
    }

    func restoreFocusToActiveLeaf() {
        guard let tree else { return }
        let targetId = tree.focusedId
        if let leaf = tree.allLeaves.first(where: { $0.id == targetId }),
           let view = surfaceViews[leaf.surfaceId],
           window?.firstResponder !== view {
            window?.makeFirstResponder(view)
        }
    }

    // MARK: - Focus navigation

    func focusLeaf(direction: SplitAxis, positive: Bool) -> String? {
        guard let tree = tree else { return nil }
        guard let currentFrame = leafFrames[tree.focusedId] else { return nil }
        let center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)

        var bestLeaf: String?
        var bestDistance: CGFloat = .greatestFiniteMagnitude

        for leaf in tree.allLeaves where leaf.id != tree.focusedId {
            guard let frame = leafFrames[leaf.id] else { continue }
            let leafCenter = CGPoint(x: frame.midX, y: frame.midY)

            let inDirection: Bool
            switch (direction, positive) {
            case (.horizontal, true):  inDirection = leafCenter.x > center.x
            case (.horizontal, false): inDirection = leafCenter.x < center.x
            case (.vertical, true):    inDirection = leafCenter.y > center.y
            case (.vertical, false):   inDirection = leafCenter.y < center.y
            }
            guard inDirection else { continue }

            let overlaps: Bool
            if direction == .horizontal {
                overlaps = frame.minY < currentFrame.maxY && frame.maxY > currentFrame.minY
            } else {
                overlaps = frame.minX < currentFrame.maxX && frame.maxX > currentFrame.minX
            }
            guard overlaps else { continue }

            let dist = hypot(leafCenter.x - center.x, leafCenter.y - center.y)
            if dist < bestDistance {
                bestDistance = dist
                bestLeaf = leaf.id
            }
        }

        if let best = bestLeaf {
            tree.focusedId = best
            delegate?.splitContainer(self, didChangeFocus: best)
            updateDimOverlays()
        }
        return bestLeaf
    }

    func dividerDidMove(_ splitNodeId: String, newRatio: CGFloat) {
        tree?.updateRatio(splitId: splitNodeId, newRatio: newRatio)
        layoutTree()
        delegate?.splitContainerDidChangeLayout(self)
    }

    func dividerDidDoubleClick(_ splitNodeId: String) {
        tree?.updateRatio(splitId: splitNodeId, newRatio: 0.5)
        layoutTree()
        delegate?.splitContainerDidChangeLayout(self)
    }
}
